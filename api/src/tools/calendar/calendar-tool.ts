import type { ToolContext, ToolDefinition } from "../types";
import { ToolError } from "../types";
import type { CalendarEvent, CalendarReadClient } from "./calendar-client";

export interface CalendarSearchInput { timeMin: string; timeMax: string; timezone?: string }
export class CalendarSearchTool implements ToolDefinition<CalendarEvent[]> {
  name = "google_calendar.search_events";
  description = "Search read-only Google Calendar events in an RFC3339 time range.";
  policy = "AUTO" as const;
  requiresApproval = false as const;
  inputSchema = {
    type: "object",
    properties: {
      timeMin: { type: "string", description: "RFC3339 inclusive range start" },
      timeMax: { type: "string", description: "RFC3339 exclusive range end" },
      timezone: { type: "string", description: "IANA timezone" },
    },
    required: ["timeMin", "timeMax"],
  };
  constructor(private readonly client: CalendarReadClient) {}
  async execute(rawInput: Record<string, unknown>, context: ToolContext): Promise<CalendarEvent[]> {
    const input = rawInput as unknown as CalendarSearchInput;
    if (!isDate(input.timeMin) || !isDate(input.timeMax)) throw new ToolError("Invalid date range", "일정 조회 날짜 범위를 해석하지 못했습니다.");
    try { return await this.client.listEvents({ timeMin: input.timeMin, timeMax: input.timeMax, timezone: context.timezone }); }
    catch (error) { throw new ToolError("Calendar search failed", "Google Calendar를 조회할 수 없습니다. Google 연결 상태를 확인해 주세요.", { cause: error }); }
  }
  summarize(result: CalendarEvent[]): string { return `Calendar events: ${result.length}`; }
}
function isDate(value: string): boolean { return typeof value === "string" && !Number.isNaN(Date.parse(value)); }
