import { env, exports } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { Env } from "../src/env";

type TestHandler = {
  fetch(request: Request, env: Env): Promise<Response>;
};

const handler = (exports as unknown as { default: TestHandler }).default;
const testEnv = env as unknown as Env;
afterEach(() => vi.useRealTimers());

describe("Jarvis Phase 1 Worker", () => {
  it("rejects unauthenticated agent requests", async () => {
    const response = await handler.fetch(new Request("https://example.test/api/agent/message", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ message: "안녕" }),
    }), testEnv);

    expect(response.status).toBe(401);
  });

  it("routes a request through the Agent and persists the run in SQLite", async () => {
    const response = await handler.fetch(new Request("https://example.test/api/agent/message", {
      method: "POST",
      headers: {
        authorization: "Bearer test-token",
        "content-type": "application/json",
      },
      body: JSON.stringify({ message: "안녕 Jarvis", sessionId: "phase1-session" }),
    }), testEnv);

    expect(response.status).toBe(200);
    const body = await response.json<{
      message: string;
      model: string;
      requestId: string;
      toolCalls: unknown[];
      approvalRequired: boolean;
    }>();
    expect(body).toMatchObject({
      message: "안녕하세요. Jarvis 테스트 응답입니다.",
      model: "test-model",
      toolCalls: [],
      approvalRequired: false,
      sessionId: "phase1-session",
    });
    expect(body.requestId).toBeTruthy();

    const agent = testEnv.PERSONAL_ASSISTANT_AGENT.getByName("primary");
    await expect(agent.stateSnapshot()).resolves.toMatchObject({
      requestCount: 1,
      sqliteConnected: true,
    });
    await expect(agent.latestRun()).resolves.toMatchObject({
      id: body.requestId,
      request: "안녕 Jarvis",
      response: body.message,
      status: "completed",
    });
  });

  it("persists conversations and isolates sessions", async () => {
    await sendMessage("session-a", "A의 첫 메시지");
    await sendMessage("session-b", "B의 첫 메시지");

    const sessionA = await api("/api/conversations/session-a");
    const sessionB = await api("/api/conversations/session-b");
    const a = await sessionA.json<{ messages: Array<{ content: string }> }>();
    const b = await sessionB.json<{ messages: Array<{ content: string }> }>();
    expect(a.messages.map((message) => message.content)).toContain("A의 첫 메시지");
    expect(a.messages.map((message) => message.content)).not.toContain("B의 첫 메시지");
    expect(b.messages.map((message) => message.content)).toContain("B의 첫 메시지");
  });

  it("supports profile and long-term memory CRUD", async () => {
    const profileCreate = await api("/api/memories", {
      method: "POST",
      body: JSON.stringify({ type: "profile", key: "timezone", value: "Asia/Seoul", source: "user" }),
    });
    expect(profileCreate.status).toBe(201);

    const longTermCreate = await api("/api/memories", {
      method: "POST",
      body: JSON.stringify({ type: "long_term", content: "오전 회의는 피한다", category: "preference", source: "user" }),
    });
    const longTerm = await longTermCreate.json<{ id: string }>();
    expect(longTermCreate.status).toBe(201);

    const profileUpdate = await api("/api/memories/profile%3Atimezone", {
      method: "PATCH",
      body: JSON.stringify({ value: "Asia/Tokyo" }),
    });
    expect(await profileUpdate.json()).toMatchObject({ value: "Asia/Tokyo" });

    const memories = await (await api("/api/memories")).json<{
      profile: Array<{ key: string; value: string }>;
      longTerm: Array<{ id: string }>;
    }>();
    expect(memories.profile).toContainEqual(expect.objectContaining({ key: "timezone", value: "Asia/Tokyo" }));
    expect(memories.longTerm).toContainEqual(expect.objectContaining({ id: longTerm.id }));

    expect((await api(`/api/memories/${longTerm.id}`, { method: "DELETE" })).status).toBe(200);
    const afterDelete = await (await api("/api/memories")).json<{ longTerm: Array<{ id: string }> }>();
    expect(afterDelete.longTerm).not.toContainEqual(expect.objectContaining({ id: longTerm.id }));
  });

  it("stores explicit memory commands and reports memory debug data", async () => {
    const response = await sendMessage("memory-session", "기억해줘. 일정은 항상 한국 시간 기준으로 알려줘.");
    const body = await response.json<{
      message: string;
      model: string;
      memory: { savedMemoryId: string; longTermMemoryCount: number; conversationMessageCount: number };
    }>();
    expect(body.message).toBe("기억했습니다.");
    expect(body.model).toBe("jarvis-memory");
    expect(body.memory.savedMemoryId).toBeTruthy();
    expect(body.memory.longTermMemoryCount).toBe(1);
    expect(body.memory.conversationMessageCount).toBe(2);

    const memories = await (await api("/api/memories")).json<{ longTerm: Array<{ content: string }> }>();
    expect(memories.longTerm[0]?.content).toContain("한국 시간 기준");
  });

  it("selects a Calendar tool, contains external failure, and records execution", async () => {
    const response = await sendMessage("tool-session", "오늘 일정 알려줘");
    const body = await response.json<{
      message: string;
      toolCalls: Array<{ name: string }>;
      toolResults: Array<{ name: string; success: boolean; error: string }>;
    }>();
    expect(response.status).toBe(200);
    expect(body.toolCalls[0]?.name).toBe("google_calendar.search_events");
    expect(body.toolResults[0]).toMatchObject({ name: "google_calendar.search_events", success: false });

    const history = await (await api("/api/tool-executions")).json<{
      executions: Array<{ toolName: string; success: boolean }>;
    }>();
    expect(history.executions[0]).toMatchObject({ toolName: "google_calendar.search_events", success: false });
  });

  it("creates a pending Gmail send approval without executing the Tool", async () => {
    const response = await sendMessage("approval-send", "메일 보내줘");
    const body = await response.json<{ approvalRequired: boolean; approval: { approvalId: string; status: string; toolName: string }; toolResults: unknown[] }>();
    expect(response.status).toBe(200);
    expect(body.approvalRequired).toBe(true);
    expect(body.approval).toMatchObject({ status: "PENDING", toolName: "gmail.send" });
    expect(body.toolResults).toEqual([]);
    const detail = await api(`/api/approvals/${body.approval.approvalId}`);
    expect(await detail.json()).toMatchObject({ status: "PENDING", toolArguments: { body: "Test message" } });
  });

  it("rejects an approval and prevents a later approve", async () => {
    const created = await (await sendMessage("approval-reject", "메일 보내줘")).json<{ approval: { approvalId: string } }>();
    const rejected = await api(`/api/approvals/${created.approval.approvalId}/reject`, { method: "POST" });
    expect(await rejected.json()).toMatchObject({ ok: true, approval: { status: "REJECTED" } });
    const approve = await api(`/api/approvals/${created.approval.approvalId}/approve`, { method: "POST" });
    expect(approve.status).toBe(409);
    expect(await approve.json()).toMatchObject({ code: "ALREADY_RESOLVED", approval: { status: "REJECTED" } });
  });

  it("claims an approval once and blocks duplicate approve retries", async () => {
    const created = await (await sendMessage("approval-approve", "일정 만들어줘")).json<{ approval: { approvalId: string } }>();
    const first = await api(`/api/approvals/${created.approval.approvalId}/approve`, { method: "POST" });
    expect(await first.json()).toMatchObject({ ok: true, approval: { status: "FAILED" } });
    const second = await api(`/api/approvals/${created.approval.approvalId}/approve`, { method: "POST" });
    expect(second.status).toBe(409);
    expect(await second.json()).toMatchObject({ code: "ALREADY_RESOLVED", approval: { status: "FAILED" } });
  });

  it("returns not found for an unknown approval", async () => {
    expect((await api("/api/approvals/missing/approve", { method: "POST" })).status).toBe(404);
    expect((await api("/api/approvals/missing")).status).toBe(404);
  });

  it.each([
    ["답장해줘", "gmail.reply"],
    ["일정 만들어줘", "calendar.create"],
    ["일정 수정해줘", "calendar.update"],
    ["일정 삭제해줘", "calendar.delete"],
  ])("creates approval for %s without executing it", async (message, toolName) => {
    const body = await (await sendMessage(`approval-${toolName}`, message)).json<{
      approval: { toolName: string; status: string }; toolResults: unknown[];
    }>();
    expect(body.approval).toMatchObject({ toolName, status: "PENDING" });
    expect(body.toolResults).toEqual([]);
  });

  it("expires a pending approval and never executes it", async () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-08-12T00:00:00Z"));
    const created = await (await sendMessage("approval-expired", "메일 보내줘")).json<{ approval: { approvalId: string } }>();
    vi.setSystemTime(new Date("2026-08-14T00:00:00Z"));
    const response = await api(`/api/approvals/${created.approval.approvalId}/approve`, { method: "POST" });
    expect(response.status).toBe(410);
    expect(await response.json()).toMatchObject({ code: "EXPIRED", approval: { status: "EXPIRED" } });
  });
});

function api(path: string, init: RequestInit = {}): Promise<Response> {
  return handler.fetch(new Request(`https://example.test${path}`, {
    ...init,
    headers: {
      authorization: "Bearer test-token",
      "content-type": "application/json",
      ...init.headers,
    },
  }), testEnv);
}

function sendMessage(sessionId: string, message: string): Promise<Response> {
  return api("/api/agent/message", {
    method: "POST",
    body: JSON.stringify({ sessionId, message }),
  });
}
