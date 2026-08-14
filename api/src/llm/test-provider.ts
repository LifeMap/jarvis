import type { LlmProvider, LlmRequest, LlmResponse, LlmToolCall, LlmToolDefinition } from "./types";

export class TestLlmProvider implements LlmProvider {
  readonly providerId = "test" as const;
  constructor(
    private readonly responseText: string,
    private readonly model = "test-model",
  ) {}

  get modelId(): string { return this.model; }

  async generate(_request: LlmRequest): Promise<LlmResponse> {
    return { text: this.responseText, model: this.model };
  }

  async generateWithToolResult(_request: LlmRequest, _call: LlmToolCall, _result: unknown): Promise<LlmResponse> {
    return { text: this.responseText, model: this.model };
  }

  async selectTool(request: LlmRequest, tools: LlmToolDefinition[]): Promise<LlmToolCall | null> {
    const text = request.messages.at(-1)?.content ?? "";
    const name = /(?:분|시간)\s*(?:뒤|후)|내일.*(?:시에|알려|실행)|매일|매주|schedule|remind/i.test(text) ? "scheduler.create"
      : /답장|reply/i.test(text) ? "gmail.reply"
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
      arguments: name === "scheduler.create" ? (/매일|매주/i.test(text)
        ? { title:"Jarvis recurring task",instruction:/메일/i.test(text)?"오늘 받은 중요한 메일을 정리해줘":"오늘 일정 알려줘",scheduleType:"recurring",scheduleRule:{frequency:/매주/i.test(text)?"weekly":"daily",...(/매주/i.test(text)?{weekday:1}:{}),hour:8,minute:0} }
        : { title:"Jarvis scheduled task",instruction:/메일.*보내/i.test(text)?"메일 보내줘":"테스트 작업 실행해줘",scheduleType:"one_time",scheduleRule:{runAt:new Date(now.getTime()+300_000).toISOString()} })
        : name === "gmail.send" ? { to: "recipient@example.com", subject: "Jarvis test", body: "Test message" }
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
