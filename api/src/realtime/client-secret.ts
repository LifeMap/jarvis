import { redactText } from "../security/redaction";

export const DEFAULT_REALTIME_MODEL = "gpt-realtime-2.1-mini";

export type MintRealtimeClientSecretInput = {
  openaiAPIKey: string;
  baseURL: string;
  model: string;
};

export type MintedRealtimeClientSecret = {
  value: string;
  expiresAt: number;
  model: string;
};

export async function mintRealtimeClientSecret(
  input: MintRealtimeClientSecretInput,
): Promise<MintedRealtimeClientSecret> {
  if (!input.openaiAPIKey) {
    throw new Error("OPENAI_API_KEY is not configured");
  }

  const base = input.baseURL.replace(/\/$/, "");
  const response = await fetch(`${base}/realtime/client_secrets`, {
    method: "POST",
    headers: {
      authorization: `Bearer ${input.openaiAPIKey}`,
      "content-type": "application/json",
    },
    body: JSON.stringify({
      expires_after: { anchor: "created_at", seconds: 600 },
      session: { type: "realtime", model: input.model },
    }),
  });

  if (!response.ok) {
    throw new Error(`Realtime credential mint failed (${response.status})`);
  }

  const payload = await response.json() as {
    value?: unknown;
    expires_at?: unknown;
    session?: { model?: unknown };
  };
  if (typeof payload.value !== "string" || payload.value.length === 0) {
    throw new Error("Realtime credential mint failed");
  }
  const expiresAt = typeof payload.expires_at === "number" ? payload.expires_at : 0;
  const model = typeof payload.session?.model === "string" && payload.session.model
    ? payload.session.model
    : input.model;
  return { value: payload.value, expiresAt, model };
}

export function realtimeMintErrorDetail(error: unknown): string {
  return redactText(error instanceof Error ? error.message : "Realtime credential mint failed").slice(0, 200);
}
