export interface CalendarEvent {
  id: string; title: string; start: string; end: string; location: string;
  description: string; attendees: string[];
}
export interface CalendarWriteInput { title: string; start: string; end: string; timezone: string; location?: string; description?: string; attendees?: string[] }
export interface CalendarClient extends CalendarReadClient, CalendarMutationClient {}
export interface CalendarReadClient {
  listEvents(input: { timeMin: string; timeMax: string; timezone: string }): Promise<CalendarEvent[]>;
}
export interface CalendarMutationClient {
  createEvent(input: CalendarWriteInput): Promise<CalendarEvent>;
  updateEvent(eventId: string, input: CalendarWriteInput): Promise<CalendarEvent>;
  deleteEvent(eventId: string): Promise<{ eventId: string; deleted: true }>;
}

interface GoogleEvent {
  id: string; summary?: string; start?: { dateTime?: string; date?: string }; end?: { dateTime?: string; date?: string };
  location?: string; description?: string; attendees?: Array<{ email?: string; displayName?: string }>;
}

export class GoogleCalendarClient implements CalendarClient {
  constructor(private readonly getAccessToken: () => Promise<string>, private readonly fetcher: typeof fetch = fetch) {}
  async listEvents(input: { timeMin: string; timeMax: string; timezone: string }): Promise<CalendarEvent[]> {
    const url = new URL("https://www.googleapis.com/calendar/v3/calendars/primary/events");
    url.search = new URLSearchParams({
      timeMin: input.timeMin, timeMax: input.timeMax, timeZone: input.timezone,
      singleEvents: "true", orderBy: "startTime", maxResults: "50",
    }).toString();
    const response = await this.fetcher(url, { headers: { authorization: `Bearer ${await this.getAccessToken()}` } });
    if (!response.ok) throw new Error(`Calendar API 요청 실패 (${response.status})`);
    const payload = await response.json() as { items?: GoogleEvent[] };
    return (payload.items ?? []).map((event) => ({
      id: event.id,
      title: event.summary ?? "(제목 없음)",
      start: event.start?.dateTime ?? event.start?.date ?? "",
      end: event.end?.dateTime ?? event.end?.date ?? "",
      location: event.location ?? "",
      description: (event.description ?? "").slice(0, 1000),
      attendees: (event.attendees ?? []).map((attendee) => attendee.displayName ?? attendee.email ?? "").filter(Boolean),
    }));
  }
  async createEvent(input: CalendarWriteInput): Promise<CalendarEvent> {
    return this.mutate("POST", "https://www.googleapis.com/calendar/v3/calendars/primary/events", input);
  }
  async updateEvent(eventId: string, input: CalendarWriteInput): Promise<CalendarEvent> {
    return this.mutate("PUT", `https://www.googleapis.com/calendar/v3/calendars/primary/events/${encodeURIComponent(eventId)}`, input);
  }
  async deleteEvent(eventId: string): Promise<{ eventId: string; deleted: true }> {
    const response = await this.fetcher(`https://www.googleapis.com/calendar/v3/calendars/primary/events/${encodeURIComponent(eventId)}`, {
      method: "DELETE", headers: { authorization: `Bearer ${await this.getAccessToken()}` },
    });
    if (!response.ok) throw new Error(`Calendar API 삭제 실패 (${response.status})`);
    return { eventId, deleted: true };
  }
  private async mutate(method: "POST" | "PUT", url: string, input: CalendarWriteInput): Promise<CalendarEvent> {
    const response = await this.fetcher(url, {
      method,
      headers: { authorization: `Bearer ${await this.getAccessToken()}`, "content-type": "application/json" },
      body: JSON.stringify({
        summary: input.title,
        start: { dateTime: input.start, timeZone: input.timezone },
        end: { dateTime: input.end, timeZone: input.timezone },
        ...(input.location ? { location: input.location } : {}),
        ...(input.description ? { description: input.description } : {}),
        ...(input.attendees?.length ? { attendees: input.attendees.map((email) => ({ email })) } : {}),
      }),
    });
    if (!response.ok) throw new Error(`Calendar API 저장 실패 (${response.status})`);
    const event = await response.json() as GoogleEvent;
    return normalizeEvent(event);
  }
}

function normalizeEvent(event: GoogleEvent): CalendarEvent {
  return {
    id: event.id, title: event.summary ?? "(제목 없음)", start: event.start?.dateTime ?? event.start?.date ?? "",
    end: event.end?.dateTime ?? event.end?.date ?? "", location: event.location ?? "",
    description: (event.description ?? "").slice(0, 1000),
    attendees: (event.attendees ?? []).map((attendee) => attendee.displayName ?? attendee.email ?? "").filter(Boolean),
  };
}
