import type { CalendarEvent, CalendarMutationClient, CalendarWriteInput } from "./calendar-client";
import type { ToolContext, ToolDefinition } from "../types";
import { ToolError } from "../types";

abstract class CalendarWriteTool<TResult> implements ToolDefinition<TResult> {
  abstract name: string;
  abstract description: string;
  abstract inputSchema: Record<string, unknown>;
  policy = "APPROVAL_REQUIRED" as const;
  requiresApproval = true as const;
  constructor(protected readonly client: CalendarMutationClient) {}
  abstract execute(input: Record<string, unknown>, context: ToolContext): Promise<TResult>;
  abstract summarize(result: TResult): string;
  protected event(input: Record<string, unknown>, timezone: string): CalendarWriteInput {
    const start = dateTime(input.start, "start");
    const end = dateTime(input.end, "end");
    if (Date.parse(end) <= Date.parse(start)) throw new ToolError("Invalid event range", "일정 종료 시간은 시작 시간보다 늦어야 합니다.");
    const location = optionalText(input.location, 1000);
    const description = optionalText(input.description, 5000);
    const attendees = emails(input.attendees);
    return {
      title: text(input.title, "title", 1000), start, end, timezone,
      ...(location ? { location } : {}), ...(description ? { description } : {}),
      ...(attendees.length ? { attendees } : {}),
    };
  }
  protected wrap(error: unknown): never {
    if (error instanceof ToolError) throw error;
    throw new ToolError("Calendar write failed", "Google Calendar 작업을 실행할 수 없습니다. Google 연결 상태를 확인해 주세요.", { cause: error });
  }
}

export class CalendarCreateTool extends CalendarWriteTool<CalendarEvent> {
  name = "calendar.create";
  description = "Create a Google Calendar event. Requires explicit user approval.";
  inputSchema = eventSchema(false);
  async execute(input: Record<string, unknown>, context: ToolContext) {
    try { return await this.client.createEvent(this.event(input, context.timezone)); } catch (error) { return this.wrap(error); }
  }
  summarize(result: CalendarEvent) { return `Calendar event created: ${result.id}`; }
}
export class CalendarUpdateTool extends CalendarWriteTool<CalendarEvent> {
  name = "calendar.update";
  description = "Update a Google Calendar event. Requires explicit user approval.";
  inputSchema = eventSchema(true);
  async execute(input: Record<string, unknown>, context: ToolContext) {
    try { return await this.client.updateEvent(text(input.eventId, "eventId", 1024), this.event(input, context.timezone)); } catch (error) { return this.wrap(error); }
  }
  summarize(result: CalendarEvent) { return `Calendar event updated: ${result.id}`; }
}
export class CalendarDeleteTool extends CalendarWriteTool<{ eventId: string; deleted: true }> {
  name = "calendar.delete";
  description = "Delete a Google Calendar event. Requires explicit user approval.";
  inputSchema = { type: "object", properties: { eventId: { type: "string" } }, required: ["eventId"] };
  async execute(input: Record<string, unknown>, _context: ToolContext) {
    try { return await this.client.deleteEvent(text(input.eventId, "eventId", 1024)); } catch (error) { return this.wrap(error); }
  }
  summarize(result: { eventId: string }) { return `Calendar event deleted: ${result.eventId}`; }
}

function eventSchema(update: boolean) {
  return { type: "object", properties: {
    ...(update ? { eventId: { type: "string" } } : {}), title: { type: "string" },
    start: { type: "string", description: "RFC3339 with UTC offset" }, end: { type: "string", description: "RFC3339 with UTC offset" },
    location: { type: "string" }, description: { type: "string" }, attendees: { type: "array", items: { type: "string" } },
  }, required: update ? ["eventId", "title", "start", "end"] : ["title", "start", "end"] };
}
function text(value: unknown, name: string, max: number): string {
  if (typeof value !== "string" || !value.trim() || value.length > max) throw new ToolError(`Invalid ${name}`, `${name} 값이 올바르지 않습니다.`);
  return value.trim();
}
function optionalText(value: unknown, max: number): string | undefined { return typeof value === "string" && value.trim() ? value.trim().slice(0, max) : undefined; }
function dateTime(value: unknown, name: string): string {
  const result = text(value, name, 100);
  if (Number.isNaN(Date.parse(result)) || !/(Z|[+-]\d{2}:\d{2})$/.test(result)) throw new ToolError(`Invalid ${name}`, `${name} 시간은 UTC offset이 포함된 RFC3339 형식이어야 합니다.`);
  return result;
}
function emails(value: unknown): string[] {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > 50 || value.some((item) => typeof item !== "string" || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(item))) {
    throw new ToolError("Invalid attendees", "참석자 이메일 목록이 올바르지 않습니다.");
  }
  return value as string[];
}
