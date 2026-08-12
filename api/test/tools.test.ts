import { describe, expect, it, vi } from "vitest";
import { CalendarSearchTool } from "../src/tools/calendar/calendar-tool";
import type { CalendarClient } from "../src/tools/calendar/calendar-client";
import { GmailSearchTool } from "../src/tools/gmail/gmail-tool";
import type { GmailClient } from "../src/tools/gmail/gmail-client";
import { BraveSearchProvider } from "../src/tools/search/search-provider";
import { GmailReplyTool, GmailSendTool } from "../src/tools/gmail/gmail-write-tools";
import { CalendarCreateTool, CalendarDeleteTool, CalendarUpdateTool } from "../src/tools/calendar/calendar-write-tools";
import type { CalendarMutationClient } from "../src/tools/calendar/calendar-client";
import { ToolRegistry } from "../src/tools/tool-registry";
import type { Env } from "../src/env";
import { ToolExecutionRepository } from "../src/tools/tool-execution-repository";
import type { SqlExecutor } from "../src/storage/sql";

describe("External tools", () => {
  it("builds Gmail search syntax and normalizes the result contract", async () => {
    const search = vi.fn<GmailClient["search"]>().mockResolvedValue([{
      id: "m1", threadId: "t1", subject: "Cloudflare", from: "kim@example.com",
      receivedAt: "2026-08-12T00:00:00Z", snippet: "hello", bodyExcerpt: "body",
    }]);
    const result = await new GmailSearchTool({ search }).execute(
      { from: "kim@example.com", keyword: "Cloudflare", maxResults: 3 },
      { timezone: "Asia/Seoul" },
    );
    expect(search).toHaveBeenCalledWith({ query: "from:(kim@example.com) Cloudflare", maxResults: 3 });
    expect(result[0]).toMatchObject({ subject: "Cloudflare", threadId: "t1" });
  });

  it("blocks direct execution of approval-required tools at the registry policy boundary", async () => {
    const oauth = { getAccessToken: vi.fn().mockResolvedValue("token") };
    const registry = new ToolRegistry({ SEARCH_PROVIDER: "none" } as Env, oauth as never);
    await expect(registry.execute("gmail.send", { to: "a@example.com", subject: "s", body: "secret" }, { timezone: "Asia/Seoul" }))
      .rejects.toMatchObject({ code: "APPROVAL_REQUIRED" });
  });

  it.each([
    [GmailSendTool, { to: "a@example.com", subject: "Hello", body: "Body" }],
    [GmailReplyTool, { to: "a@example.com", subject: "Re: Hello", body: "Reply", threadId: "t1" }],
  ])("executes approved Gmail write handler contract for %s", async (ToolClass, input) => {
    const send = vi.fn().mockResolvedValue({ id: "m1", threadId: "t1" });
    await new ToolClass({ send }).execute(input, { timezone: "Asia/Seoul" });
    expect(send).toHaveBeenCalledOnce();
  });

  it("uses Profile timezone unchanged for Calendar create/update and supports delete", async () => {
    const event = { id: "e1", title: "Meeting", start: "2026-08-13T10:00:00+09:00", end: "2026-08-13T11:00:00+09:00", location: "", description: "", attendees: [] };
    const client: CalendarMutationClient = {
      createEvent: vi.fn().mockResolvedValue(event), updateEvent: vi.fn().mockResolvedValue(event),
      deleteEvent: vi.fn().mockResolvedValue({ eventId: "e1", deleted: true }),
    };
    const eventInput = { title: "Meeting", start: "2026-08-13T10:00:00+09:00", end: "2026-08-13T11:00:00+09:00" };
    await new CalendarCreateTool(client).execute(eventInput, { timezone: "Asia/Seoul" });
    await new CalendarUpdateTool(client).execute({ eventId: "e1", ...eventInput }, { timezone: "Asia/Seoul" });
    await new CalendarDeleteTool(client).execute({ eventId: "e1" }, { timezone: "Asia/Seoul" });
    expect(client.createEvent).toHaveBeenCalledWith(expect.objectContaining({ timezone: "Asia/Seoul", start: eventInput.start }));
    expect(client.updateEvent).toHaveBeenCalledWith("e1", expect.objectContaining({ timezone: "Asia/Seoul" }));
    expect(client.deleteEvent).toHaveBeenCalledWith("e1");
  });

  it("validates write arguments before an external handler is called", async () => {
    const send = vi.fn().mockResolvedValue({ id: "m1", threadId: "t1" });
    await expect(new GmailSendTool({ send }).execute({ to: "not-an-email", subject: "s", body: "b" }, { timezone: "UTC" })).rejects.toThrow();
    expect(send).not.toHaveBeenCalled();
  });

  it("redacts message bodies and descriptions from execution logs", () => {
    const values: unknown[][] = [];
    const database: SqlExecutor = { sql: (_strings, ...parameters) => { values.push(parameters); return []; } };
    new ToolExecutionRepository(database).record({
      id: "x1", requestId: "r1", toolName: "gmail.send",
      toolInput: { to: "a@example.com", body: "private body", description: "private event", apiKey: "not-a-runtime-secret" },
      success: true, durationMs: 1, resultSummary: "sent",
    });
    const serializedInput = String(values[0]?.[3]);
    expect(serializedInput).not.toContain("private body");
    expect(serializedInput).not.toContain("private event");
    expect(serializedInput).not.toContain("not-a-runtime-secret");
    expect(serializedInput).toContain("[REDACTED 12 chars]");
  });

  it("forces the Profile timezone when querying Calendar", async () => {
    const listEvents = vi.fn<CalendarClient["listEvents"]>().mockResolvedValue([]);
    await new CalendarSearchTool({ listEvents }).execute({
      timeMin: "2026-08-12T00:00:00Z",
      timeMax: "2026-08-13T00:00:00Z",
      timezone: "America/New_York",
    }, { timezone: "Asia/Seoul" });
    expect(listEvents).toHaveBeenCalledWith(expect.objectContaining({ timezone: "Asia/Seoul" }));
  });

  it("normalizes Brave Search results", async () => {
    const fetcher = vi.fn<typeof fetch>().mockResolvedValue(Response.json({
      web: { results: [{ title: "Cloudflare Agents", url: "https://developers.cloudflare.com/agents/", description: "Build agents" }] },
    }));
    const results = await new BraveSearchProvider("secret", fetcher).search("Cloudflare Agents", 5);
    expect(results).toEqual([{
      title: "Cloudflare Agents", url: "https://developers.cloudflare.com/agents/",
      snippet: "Build agents", source: "developers.cloudflare.com",
    }]);
    expect(fetcher).toHaveBeenCalledOnce();
  });
});
