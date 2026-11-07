import { normalizeCalendarName, type CalendarCatalogClient, type CalendarCreationRepository, type EnsureCalendarResult, type NamedCalendar } from './calendar-catalog';
import { ToolError } from '../types';
export interface CalendarEvent {
  id: string; title: string; start: string; end: string; location: string;
  description: string; attendees: string[];
}
export interface CalendarWriteInput { title: string; start: string; end: string; timezone: string; location?: string; description?: string; attendees?: string[] }
export interface CalendarClient extends CalendarReadClient, CalendarMutationClient { ensureCalendar?: CalendarCatalogClient["ensureCalendar"] }
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
  constructor(private readonly getAccessToken: () => Promise<string>, private readonly fetcher: typeof fetch = (input, init) => fetch(input, init), private readonly creationGuard?:Pick<CalendarCreationRepository,"reserve"|"release">) {}
  async ensureCalendar(input:{name:string;timezone:string}):Promise<EnsureCalendarResult> {
    const name=input.name.normalize('NFC').trim();
    if(!name||name.length>200)throw new Error('Invalid calendar name');
    new Intl.DateTimeFormat('en',{timeZone:input.timezone});
    const matches:NamedCalendar[]=[],seen=new Set<string>();let pageToken='';
    do {
      const url=new URL('https://www.googleapis.com/calendar/v3/users/me/calendarList');
      url.search=new URLSearchParams({maxResults:'250',showHidden:'true',...(pageToken?{pageToken}:{})}).toString();
      const response=await this.fetcher(url,{headers:{authorization:`Bearer ${await this.getAccessToken()}`},signal:AbortSignal.timeout(10000)});
      if(!response.ok)throw new Error(`Calendar list failed (${response.status})`);
      const data=await response.json() as {items?:Array<{id?:string;summary?:string;accessRole?:string;deleted?:boolean}>;nextPageToken?:string};
      if(!Array.isArray(data.items))throw new Error('Incomplete calendar list');
      for(const item of data.items){
        if(item.deleted)continue;
        if(typeof item.id!=='string'||typeof item.summary!=='string')throw new Error('Invalid calendar entry');
        if(normalizeCalendarName(item.summary)===normalizeCalendarName(name))matches.push({id:item.id,name:item.summary,writable:['owner','writer'].includes(item.accessRole??'')});
      }
      pageToken=data.nextPageToken??'';
      if(pageToken&&(seen.has(pageToken)||seen.size>=100))throw new Error('Incomplete calendar pagination');
      seen.add(pageToken);
    }while(pageToken);
    if(matches.length){this.creationGuard?.release(name);return {created:false,calendars:matches};}
    if(!this.creationGuard)throw new Error('Calendar creation guard unavailable');
    // Reserve synchronously before awaiting POST. A timeout keeps the guard until a later list finds the calendar.
    const token=await this.getAccessToken();
    if(!this.creationGuard.reserve(name))throw new ToolError('Calendar creation uncertain','같은 이름의 캘린더 생성이 진행 중이거나 이전 생성 결과를 확인하지 못했습니다. Google 캘린더에서 확인해 주세요.');
    const response=await this.fetcher('https://www.googleapis.com/calendar/v3/calendars',{method:'POST',headers:{authorization:`Bearer ${token}`,'content-type':'application/json'},body:JSON.stringify({summary:name,timeZone:input.timezone}),signal:AbortSignal.timeout(10000)});
    if(!response.ok){if([400,401,403,404,422,429].includes(response.status))this.creationGuard.release(name);throw new Error(`Calendar create failed (${response.status})`);}
    const created=await response.json() as {id?:string;summary?:string};
    if(typeof created.id!=='string'||!created.id)throw new Error('Invalid created calendar');
    // Keep the guard even on success until listing confirms visibility, preventing eventual-consistency duplicates.
    return {created:true,calendars:[{id:created.id,name:created.summary??name,writable:true}]};
  }
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
