import type { LlmProvider, LlmRequest, LlmResponse, LlmToolCall, LlmToolDefinition } from "./types";

export class TestLlmProvider implements LlmProvider {
  constructor(
    private readonly responseText: string,
    private readonly model = "test-model",
  ) {}

  async generate(_request: LlmRequest): Promise<LlmResponse> {
    return { text: this.responseText, model: this.model };
  }

  async generateWithToolResult(_request: LlmRequest, _call: LlmToolCall, _result: unknown): Promise<LlmResponse> {
    return { text: this.responseText, model: this.model };
  }

  async selectTool(request: LlmRequest, tools: LlmToolDefinition[]): Promise<LlmToolCall | null> {
    const text = request.messages.at(-1)?.content ?? "";
    const name = /답장|reply/i.test(text) ? "gmail.reply"
      : /(메일|email).*(보내|발송|send)|(보내|발송|send).*(메일|email)/i.test(text) ? "gmail.send"
      : /(일정|캘린더|calendar).*(삭제|delete)/i.test(text) ? "calendar.delete"
      : /(일정|캘린더|calendar).*(수정|변경|update)/i.test(text) ? "calendar.update"
      : /(일정|캘린더|calendar).*(만들|생성|추가|create)/i.test(text) ? "calendar.create"
      : /메일|gmail|email/i.test(text) ? "gmail.search_messages"
      : /일정|캘린더|calendar|schedule/i.test(text) ? "google_calendar.search_events"
        : /검색|찾아|최신|현재|search|news|weather/i.test(text) ? "web_search.search" : null;
    if (!name || !tools.some((tool) => tool.name === name)) return null;
    const now = new Date();
    return {
      id: crypto.randomUUID(),
      name,
      arguments: name === "gmail.send" ? { to: "recipient@example.com", subject: "Jarvis test", body: "Test message" }
        : name === "gmail.reply" ? { to: "recipient@example.com", subject: "Re: Jarvis test", body: "Test reply", threadId: "thread-1" }
        : name === "calendar.create" ? { title: "Jarvis test", start: "2026-08-13T10:00:00+09:00", end: "2026-08-13T11:00:00+09:00" }
        : name === "calendar.update" ? { eventId: "event-1", title: "Jarvis updated", start: "2026-08-13T10:00:00+09:00", end: "2026-08-13T11:00:00+09:00" }
        : name === "calendar.delete" ? { eventId: "event-1" }
        : name === "gmail.search_messages" ? { maxResults: 5 }
        : name === "google_calendar.search_events" ? { timeMin: now.toISOString(), timeMax: new Date(now.getTime() + 86_400_000).toISOString() }
          : { query: text, count: 5 },
    };
  }
}
