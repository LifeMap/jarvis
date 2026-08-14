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

  it("handles explicit Model Management commands without invoking the active model", async () => {
    const current = await sendMessage("model-management", "현재 어떤 모델 사용하고 있어?");
    expect(current.status).toBe(200);
    await expect(current.json()).resolves.toMatchObject({
      message: expect.stringContaining("Model: test-model"),
      model: "jarvis-model-management",
      toolCalls: [expect.objectContaining({ name: "model.get_active" })],
    });
    const defaultModel = await sendMessage("model-management", "기본 모델이 뭐야?");
    await expect(defaultModel.json()).resolves.toMatchObject({
      message: expect.stringContaining("Model: test-model"),
      toolCalls: [expect.objectContaining({ name: "model.get_default" })],
    });
    const reset = await sendMessage("model-management", "기본 모델로 되돌려");
    await expect(reset.json()).resolves.toMatchObject({
      message: expect.stringContaining("기본 모델"),
      toolCalls: [expect.objectContaining({ name: "model.reset_active" })],
      toolResults: [expect.objectContaining({ success: true })],
    });
    const invalid = await sendMessage("model-management", "Anthropic 모델로 변경해");
    await expect(invalid.json()).resolves.toMatchObject({
      message: expect.stringContaining("기존 모델 설정은 유지됩니다"),
      toolResults: [expect.objectContaining({ name: "model.set_active", success: false })],
    });
    const after = await sendMessage("model-management", "현재 모델 알려줘");
    await expect(after.json()).resolves.toMatchObject({ message: expect.stringContaining("Model: test-model") });
  });

  it("manages Tool Providers explicitly and persists changes between requests", async () => {
    const all = await sendMessage("tool-provider-management", "현재 외부 서비스 Provider 상태를 전부 보여줘.");
    await expect(all.json()).resolves.toMatchObject({
      message: expect.stringContaining("brave-api"),
      model: "jarvis-tool-provider-management",
      toolCalls: [expect.objectContaining({ name: "tool_provider.list_active" })],
    });

    const changed = await sendMessage("tool-provider-management", "Search Provider를 serpapi로 변경해.");
    await expect(changed.json()).resolves.toMatchObject({
      message: expect.stringContaining("serpapi"),
      toolResults: [expect.objectContaining({ name: "tool_provider.set_active", success: true })],
    });
    const persisted = await sendMessage("tool-provider-management", "현재 Search Provider 알려줘.");
    await expect(persisted.json()).resolves.toMatchObject({ message: expect.stringContaining("Active: serpapi") });

    const rejected = await sendMessage("tool-provider-management", "Gmail을 MCP로 바꿔.");
    await expect(rejected.json()).resolves.toMatchObject({
      message: expect.stringContaining("사용 가능한 gmail MCP Provider가 없습니다"),
      toolResults: [expect.objectContaining({ name: "runtime.apply_changes", success: false })],
    });

    const reset = await sendMessage("tool-provider-management", "Search를 기본 Provider로 되돌려.");
    await expect(reset.json()).resolves.toMatchObject({
      message: expect.stringContaining("brave-api"),
      toolResults: [expect.objectContaining({ name: "tool_provider.reset", success: true })],
    });
  });

  it("manages the unified Runtime Configuration with natural-language composite changes and history",async()=>{
    const snapshot=await sendMessage("runtime-management","현재 Jarvis 설정 알려줘.");
    await expect(snapshot.json()).resolves.toMatchObject({model:"jarvis-runtime-configuration",toolCalls:[expect.objectContaining({name:"runtime.get_configuration"})],message:expect.stringContaining("Tool Providers")});
    const changed=await sendMessage("runtime-management","모델은 기본 모델로 되돌리고 Search Provider를 serpapi로 변경해.");
    await expect(changed.json()).resolves.toMatchObject({toolCalls:[expect.objectContaining({name:"runtime.apply_changes"})],toolResults:[expect.objectContaining({success:true})],message:expect.stringContaining("tools.search")});
    const persisted=await api("/api/runtime-configuration");expect(persisted.status).toBe(200);await expect(persisted.json()).resolves.toMatchObject({model:{active:{provider:"test"}},tools:{search:{active:{providerId:"serpapi"}}}});
    const history=await sendMessage("runtime-management","최근 설정 변경 내역 보여줘.");await expect(history.json()).resolves.toMatchObject({toolCalls:[expect.objectContaining({name:"runtime.list_history"})],message:expect.stringContaining("tools.search")});
    const historyApi=await api("/api/runtime-configuration/history");const historyBody=await historyApi.json<{history:Array<{target:string}>}>();expect(historyBody.history).toEqual(expect.arrayContaining([expect.objectContaining({target:"model"}),expect.objectContaining({target:"tools.search"})]));
    await sendMessage("runtime-management","Search를 기본 Provider로 되돌려.");
  });

  it("does not create a write approval from an ambiguous answer phrase", async () => {
    const response = await sendMessage("model-tool-guard", "한 문장으로 답해줘");
    await expect(response.json()).resolves.toMatchObject({
      message: "안녕하세요. Jarvis 테스트 응답입니다.",
      toolCalls: [],
      approvalRequired: false,
    });
  });

  it("accepts a validated transient location and rejects invalid coordinates", async()=>{
    const valid=await api("/api/agent/message",{method:"POST",body:JSON.stringify({message:"내 주변 날씨",sessionId:"location-session",location:{latitude:37.5665,longitude:126.978,accuracyMeters:25,capturedAt:"2026-08-13T00:00:00.000Z",source:"browser"}})});
    expect(valid.status).toBe(200);
    await expect(valid.json()).resolves.toMatchObject({context:{location:{latitude:37.5665,longitude:126.978,accuracyMeters:25,source:"browser"}}});
    const invalid=await api("/api/agent/message",{method:"POST",body:JSON.stringify({message:"내 위치",location:{latitude:999,longitude:126.978,capturedAt:"2026-08-13T00:00:00.000Z",source:"browser"}})});
    expect(invalid.status).toBe(400);
    await expect(invalid.json()).resolves.toMatchObject({error:"Invalid location payload"});
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

  it("creates and manually executes a one-time schedule to completion", async () => {
    const createdResponse=await api("/api/schedules",{method:"POST",body:JSON.stringify({title:"test",instruction:"안녕 Jarvis",scheduleType:"one_time",scheduleRule:{runAt:new Date(Date.now()+60_000).toISOString()},timezone:"Asia/Seoul"})});
    expect(createdResponse.status).toBe(201);
    const created=await createdResponse.json<{id:string;status:string;nextRunAt:string;nativeScheduleId:string}>();
    expect(created).toMatchObject({status:"scheduled",timezone:"Asia/Seoul"});expect(created.nativeScheduleId).toBeTruthy();
    const run=await api(`/api/schedules/${created.id}/run`,{method:"POST"});
    expect(await run.json()).toMatchObject({ok:true,schedule:{status:"completed",nextRunAt:null}});
    const history=await (await api(`/api/schedule-executions?scheduleId=${created.id}`)).json<{executions:unknown[]}>();expect(history.executions).toHaveLength(1);
  });

  it("reschedules recurring tasks after each execution",async()=>{
    const created=await (await api("/api/schedules",{method:"POST",body:JSON.stringify({title:"daily",instruction:"안녕",scheduleType:"recurring",scheduleRule:{frequency:"daily",hour:8,minute:0},timezone:"Asia/Seoul"})})).json<{id:string;nextRunAt:string}>();
    const run=await (await api(`/api/schedules/${created.id}/run`,{method:"POST"})).json<{schedule:{status:string;nextRunAt:string}}>();
    expect(run.schedule.status).toBe("scheduled");expect(new Date(run.schedule.nextRunAt).getTime()).toBeGreaterThan(Date.now());
  });

  it("does not execute disabled schedules and supports update/delete",async()=>{
    const created=await (await api("/api/schedules",{method:"POST",body:JSON.stringify({title:"disabled",instruction:"안녕",scheduleType:"one_time",scheduleRule:{runAt:new Date(Date.now()+60_000).toISOString()}})})).json<{id:string}>();
    const disabled=await api(`/api/schedules/${created.id}`,{method:"PATCH",body:JSON.stringify({enabled:false})});expect(await disabled.json()).toMatchObject({enabled:false,status:"disabled"});
    expect((await api(`/api/schedules/${created.id}/run`,{method:"POST"})).status).toBe(409);
    expect((await api(`/api/schedules/${created.id}`,{method:"DELETE"})).status).toBe(200);
  });

  it("creates Approval instead of executing a scheduled write action",async()=>{
    const created=await (await api("/api/schedules",{method:"POST",body:JSON.stringify({title:"mail",instruction:"메일 보내줘",scheduleType:"one_time",scheduleRule:{runAt:new Date(Date.now()+60_000).toISOString()}})})).json<{id:string}>();
    const run=await (await api(`/api/schedules/${created.id}/run`,{method:"POST"})).json<{response:{approvalRequired:boolean;approval:{status:string;toolName:string}}}>();
    expect(run.response).toMatchObject({approvalRequired:true,approval:{status:"PENDING",toolName:"gmail.send"}});
  });

  it("prevents duplicate concurrent schedule execution",async()=>{
    const created=await (await api("/api/schedules",{method:"POST",body:JSON.stringify({title:"once",instruction:"안녕",scheduleType:"one_time",scheduleRule:{runAt:new Date(Date.now()+60_000).toISOString()}})})).json<{id:string}>();
    const responses=await Promise.all([api(`/api/schedules/${created.id}/run`,{method:"POST"}),api(`/api/schedules/${created.id}/run`,{method:"POST"})]);
    expect(responses.map(r=>r.status).sort()).toEqual([200,409]);
  });

  it("provides authenticated Admin dashboard, tools, settings and history APIs",async()=>{
    const dashboard=await api("/api/admin/dashboard");expect(dashboard.status).toBe(200);expect(await dashboard.json()).toMatchObject({counts:{pendingApprovals:expect.any(Number),activeSchedules:expect.any(Number),recentErrors:expect.any(Number)}});
    const toolList=await (await api("/api/tools")).json<{tools:Array<{name:string;requiresApproval:boolean;provider?:{implementation:string}}>}>();expect(toolList.tools).toEqual(expect.arrayContaining([expect.objectContaining({name:"gmail.send",requiresApproval:true,provider:{service:"gmail",implementation:"gmail-api"}}),expect.objectContaining({name:"scheduler.create",requiresApproval:false,provider:{service:"scheduler",implementation:"cloudflare-agents"}})]));
    const updated=await api("/api/settings",{method:"PATCH",body:JSON.stringify({language:"ko",timezone:"Asia/Seoul",responseTone:"warm",speechStyle:"polite",responseDetail:"concise",customInstructions:"결론부터 답해줘."})});expect(await updated.json()).toMatchObject({language:"ko",timezone:"Asia/Seoul",responseTone:"warm",speechStyle:"polite",responseDetail:"concise",customInstructions:"결론부터 답해줘.",llmProvider:"test",secretsManagedBy:"Cloudflare Secrets"});
    const sent=await sendMessage("admin-history","안녕 Admin");const run=await sent.json<{requestId:string}>();
    const historyList=await (await api("/api/history")).json<{runs:Array<{id:string}>}>();expect(historyList.runs).toContainEqual(expect.objectContaining({id:run.requestId}));
    expect(await (await api(`/api/history/${run.requestId}`)).json()).toMatchObject({id:run.requestId,request:"안녕 Admin",triggerType:"manual",tokenUsage:null,toolExecutions:[]});
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
