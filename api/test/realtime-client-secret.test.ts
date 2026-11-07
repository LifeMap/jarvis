import { afterEach, describe, expect, it, vi } from "vitest";
import { env, exports } from "cloudflare:workers";
import type { Env } from "../src/env";
import { mintRealtimeClientSecret } from "../src/realtime/client-secret";

type TestHandler = {
  fetch(request: Request, env: Env): Promise<Response>;
};

const handler = (exports as unknown as { default: TestHandler }).default;
const testEnv = env as unknown as Env;

afterEach(() => {
  vi.unstubAllGlobals();
  vi.useRealTimers();
});

describe("mintRealtimeClientSecret", () => {
  it("returns value expiresAt model from OpenAI", async () => {
    const fetchMock = vi.fn(async (_url: string, _init: RequestInit) => new Response(JSON.stringify({
      value: "ek_test",
      expires_at: 1_700_000_000,
      session: { model: "gpt-realtime-2.1-mini" },
    }), { status: 200 }));
    vi.stubGlobal("fetch", fetchMock);

    await expect(mintRealtimeClientSecret({
      openaiAPIKey: "sk-server",
      baseURL: "https://api.openai.com/v1",
      model: "gpt-realtime-2.1-mini",
    })).resolves.toEqual({
      value: "ek_test",
      expiresAt: 1_700_000_000,
      model: "gpt-realtime-2.1-mini",
    });

    expect(fetchMock).toHaveBeenCalledTimes(1);
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit];
    expect(url).toBe("https://api.openai.com/v1/realtime/client_secrets");
    const headers = init.headers as Record<string, string>;
    expect(headers.authorization).toBe("Bearer sk-server");
    const body = JSON.parse(String(init.body));
    expect(body.expires_after).toEqual({ anchor: "created_at", seconds: 600 });
    expect(body.session).toEqual({ type: "realtime", model: "gpt-realtime-2.1-mini" });
    expect(body.session.turn_detection).toBeUndefined();
  });

  it("throws when OpenAI key is missing", async () => {
    await expect(mintRealtimeClientSecret({
      openaiAPIKey: "",
      baseURL: "https://api.openai.com/v1",
      model: "gpt-realtime-2.1-mini",
    })).rejects.toThrow(/OPENAI_API_KEY/);
  });

  it("throws a redacted error when OpenAI fails", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(
      JSON.stringify({ error: { message: "invalid_api_key ek_should_not_leak" } }),
      { status: 401 },
    )));
    await expect(mintRealtimeClientSecret({
      openaiAPIKey: "sk-server",
      baseURL: "https://api.openai.com/v1",
      model: "gpt-realtime-2.1-mini",
    })).rejects.toThrow(/Realtime credential/);
    try {
      await mintRealtimeClientSecret({
        openaiAPIKey: "sk-server",
        baseURL: "https://api.openai.com/v1",
        model: "gpt-realtime-2.1-mini",
      });
      throw new Error("expected mint to fail");
    } catch (error) {
      expect(String(error)).not.toContain("ek_should_not_leak");
    }
  });
});

describe("POST /api/realtime/client-secret", () => {
  it("rejects unauthenticated requests", async () => {
    const response = await handler.fetch(new Request("https://example.test/api/realtime/client-secret", {
      method: "POST",
    }), testEnv);
    expect(response.status).toBe(401);
  });

  it("returns the minted secret", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify({
      value: "ek_route",
      expires_at: 1_800_000_000,
      session: { model: "gpt-realtime-2.1-mini" },
    }), { status: 200 })));

    const response = await handler.fetch(new Request("https://example.test/api/realtime/client-secret", {
      method: "POST",
      headers: {
        authorization: "Bearer test-token",
        "content-type": "application/json",
      },
      body: JSON.stringify({ model: "gpt-realtime-2.1-mini" }),
    }), { ...testEnv, OPENAI_API_KEY: "sk-test-openai" });

    expect(response.status).toBe(200);
    await expect(response.json()).resolves.toEqual({
      value: "ek_route",
      expiresAt: 1_800_000_000,
      model: "gpt-realtime-2.1-mini",
    });
  });

  it("returns 503 when OpenAI is unavailable", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response("nope", { status: 500 })));
    const response = await handler.fetch(new Request("https://example.test/api/realtime/client-secret", {
      method: "POST",
      headers: { authorization: "Bearer test-token" },
    }), { ...testEnv, OPENAI_API_KEY: "sk-test-openai" });
    expect(response.status).toBe(503);
    const body = await response.json<{ error: string; detail?: string }>();
    expect(body.error).toMatch(/Realtime/);
    expect(JSON.stringify(body)).not.toContain("ek_");
  });
});
