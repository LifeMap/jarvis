export interface GmailMessage {
  id: string;
  threadId: string;
  subject: string;
  from: string;
  receivedAt: string;
  snippet: string;
  bodyExcerpt: string;
}

export interface GmailClient extends GmailSearchClient, GmailMutationClient {}
export interface GmailSearchClient {
  search(input: { query?: string; maxResults: number }): Promise<GmailMessage[]>;
}
export interface GmailMutationClient {
  send(input: GmailSendRequest): Promise<GmailMutationResult>;
}

export interface GmailSendRequest { to: string; subject: string; body: string; threadId?: string; inReplyTo?: string }
export interface GmailMutationResult { id: string; threadId: string }
export class GmailApiError extends Error{constructor(readonly status:number,readonly reason:string){super(`Gmail API 요청 실패 (${status}): ${reason}`);this.name="GmailApiError"}}

interface GmailApiMessage {
  id: string;
  threadId: string;
  internalDate?: string;
  snippet?: string;
  payload?: GmailPart;
}
interface GmailPart { mimeType?: string; headers?: Array<{ name: string; value: string }>; body?: { data?: string }; parts?: GmailPart[] }

export class GoogleGmailClient implements GmailClient {
  constructor(private readonly getAccessToken: () => Promise<string>, private readonly fetcher: typeof fetch = (input, init) => fetch(input, init)) {}

  async search(input: { query?: string; maxResults: number }): Promise<GmailMessage[]> {
    const token = await this.getAccessToken();
    const url = new URL("https://gmail.googleapis.com/gmail/v1/users/me/messages");
    url.searchParams.set("maxResults", String(Math.min(Math.max(input.maxResults, 1), 20)));
    if (input.query) url.searchParams.set("q", input.query);
    const list = await this.request<{ messages?: Array<{ id: string }> }>(url, token);
    return Promise.all((list.messages ?? []).map(async ({ id }) => {
      const detailUrl = new URL(`https://gmail.googleapis.com/gmail/v1/users/me/messages/${encodeURIComponent(id)}`);
      detailUrl.searchParams.set("format", "full");
      return normalizeMessage(await this.request<GmailApiMessage>(detailUrl, token));
    }));
  }

  async send(input: GmailSendRequest): Promise<GmailMutationResult> {
    const token = await this.getAccessToken();
    const response = await this.fetcher("https://gmail.googleapis.com/gmail/v1/users/me/messages/send", {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify({ raw: encodeMime(input), ...(input.threadId ? { threadId: input.threadId } : {}) }),
    });
    if (!response.ok) throw await gmailApiError(response);
    const payload = await response.json() as { id?: string; threadId?: string };
    if (!payload.id || !payload.threadId) throw new Error("Gmail API 발송 응답이 올바르지 않습니다.");
    return { id: payload.id, threadId: payload.threadId };
  }

  private async request<T>(url: URL, token: string): Promise<T> {
    const response = await this.fetcher(url, { headers: { authorization: `Bearer ${token}` } });
    if (!response.ok) throw await gmailApiError(response);
    return response.json() as Promise<T>;
  }
}

async function gmailApiError(response:Response):Promise<GmailApiError>{
  let reason="Google API error";
  try{const payload=await response.json() as {error?:{message?:string;errors?:Array<{reason?:string}>}};reason=payload.error?.errors?.[0]?.reason??payload.error?.message??reason}catch{}
  return new GmailApiError(response.status,reason);
}

function encodeMime(input: GmailSendRequest): string {
  const headers = [
    `To: ${input.to}`,
    `Subject: ${input.subject}`,
    "MIME-Version: 1.0",
    "Content-Type: text/plain; charset=UTF-8",
    "Content-Transfer-Encoding: 8bit",
    ...(input.inReplyTo ? [`In-Reply-To: ${input.inReplyTo}`, `References: ${input.inReplyTo}`] : []),
  ];
  const bytes = new TextEncoder().encode(`${headers.join("\r\n")}\r\n\r\n${input.body}`);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function normalizeMessage(message: GmailApiMessage): GmailMessage {
  const headers = message.payload?.headers ?? [];
  return {
    id: message.id,
    threadId: message.threadId,
    subject: header(headers, "subject") || "(제목 없음)",
    from: header(headers, "from"),
    receivedAt: header(headers, "date") || (message.internalDate ? new Date(Number(message.internalDate)).toISOString() : ""),
    snippet: message.snippet ?? "",
    bodyExcerpt: extractBody(message.payload).slice(0, 2000),
  };
}
function header(headers: Array<{ name: string; value: string }>, name: string): string {
  return headers.find((item) => item.name.toLowerCase() === name)?.value ?? "";
}
function extractBody(part?: GmailPart): string {
  if (!part) return "";
  if (part.mimeType === "text/plain" && part.body?.data) return decodeBase64Url(part.body.data);
  return (part.parts ?? []).map(extractBody).filter(Boolean).join("\n");
}
function decodeBase64Url(value: string): string {
  try {
    const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
    const binary = atob(normalized);
    return new TextDecoder().decode(Uint8Array.from(binary, (character) => character.charCodeAt(0)));
  } catch { return ""; }
}
