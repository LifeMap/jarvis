import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import App from "./App";

afterEach(() => {
  cleanup();
  vi.restoreAllMocks();
});
beforeEach(() => window.localStorage.clear());

function json(value: unknown, status = 200) {
  return Promise.resolve(Response.json(value, { status }));
}

function mockFetch(agent: unknown) {
  return vi.spyOn(globalThis, "fetch").mockImplementation((input) => {
    if (String(input).includes("/api/calls")) return json({ calls: [] });
    return json(agent);
  });
}

describe("Jarvis Playground", () => {
  it("shows the conversation and debug fields returned by the Agent API", async () => {
    mockFetch({
      message: "테스트 응답입니다.",
      toolCalls: [],
      approvalRequired: false,
      model: "test-model",
      executionTimeMs: 18,
      requestId: "request-1",
      sessionId: "test-session",
      memory: { profileCount: 1, longTermMemoryCount: 2, conversationMessageCount: 2 },
    });
    render(<App />);

    fireEvent.change(screen.getByRole("textbox", { name: "Agent command" }), { target: { value: "오늘 일정 알려줘" } });
    fireEvent.click(screen.getByRole("button", { name: /명령 보내기/ }));

    expect(await screen.findByText("테스트 응답입니다.")).toBeInTheDocument();
    expect(screen.getByText("test-model")).toBeInTheDocument();
    expect(screen.getByText("18 ms")).toBeInTheDocument();
    expect(screen.getByText("No tool calls")).toBeInTheDocument();
    expect(screen.getByText("Not required")).toBeInTheDocument();
    expect(screen.getByText("test-session")).toBeInTheDocument();
    expect(screen.getAllByText("2", { selector: "dd" })).toHaveLength(2);
  });

  it("starts a new session and clears the visible conversation", async () => {
    mockFetch({
      message: "응답", toolCalls: [], approvalRequired: false, model: "test", executionTimeMs: 1,
      requestId: "r1", sessionId: "s1", memory: { profileCount: 0, longTermMemoryCount: 0, conversationMessageCount: 2 },
    });
    render(<App />);
    fireEvent.change(screen.getByRole("textbox", { name: "Agent command" }), { target: { value: "안녕" } });
    fireEvent.click(screen.getByRole("button", { name: /명령 보내기/ }));
    expect(await screen.findByText("응답")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "새 Session" }));
    expect(screen.queryByText("응답")).not.toBeInTheDocument();
  });

  it("shows structured Tool execution debug data", async () => {
    mockFetch({
      message: "일정 조회에 실패했습니다.",
      toolCalls: [{ id: "tc1", name: "google_calendar.search_events", input: { timeMin: "2026-08-12" }, requiresApproval: false }],
      toolResults: [{ toolCallId: "tc1", name: "google_calendar.search_events", success: false, durationMs: 12, summary: "Google 연결 필요" }],
      approvalRequired: false, model: "test", executionTimeMs: 15, requestId: "r1", sessionId: "s1",
    });
    render(<App />);
    fireEvent.change(screen.getByRole("textbox", { name: "Agent command" }), { target: { value: "오늘 일정" } });
    fireEvent.click(screen.getByRole("button", { name: /명령 보내기/ }));
    expect(await screen.findByText("google_calendar.search_events")).toBeInTheDocument();
    expect(screen.getByText("failure")).toBeInTheDocument();
    expect(screen.getByText("12 ms")).toBeInTheDocument();
    expect(screen.getByText("Google 연결 필요")).toBeInTheDocument();
  });

  it("shows a pending approval and approves it from the Playground", async () => {
    const pending = {
      approvalId: "a1", conversationId: "s1", requestId: "r1", toolCallId: "tc1", toolName: "gmail.send",
      toolArguments: { to: "kim@example.com", subject: "Hello", body: "Body" }, policy: "APPROVAL_REQUIRED", status: "PENDING",
      requestedAt: "2026-08-12T00:00:00Z", expiresAt: "2026-08-13T00:00:00Z", resolvedAt: null,
      executedAt: null, resultSummary: null, error: null, executionId: null,
    };
    const fetchMock = vi.spyOn(globalThis, "fetch").mockImplementation((input) => {
      const url = String(input);
      if (url.includes("/api/calls")) return json({ calls: [] });
      if (url.includes("/approvals/")) return json({ ok: true, approval: { ...pending, status: "EXECUTED", resultSummary: "Gmail message sent: m1" } });
      return json({
        message: "승인이 필요한 작업입니다.", toolCalls: [{ id: "tc1", name: "gmail.send", input: pending.toolArguments, requiresApproval: true, approvalId: "a1" }],
        toolResults: [], approvalRequired: true, approval: pending, model: "jarvis-approval", executionTimeMs: 3, requestId: "r1", sessionId: "s1",
      });
    });
    render(<App />);
    fireEvent.change(screen.getByRole("textbox", { name: "Agent command" }), { target: { value: "메일 보내줘" } });
    fireEvent.click(screen.getByRole("button", { name: /명령 보내기/ }));
    expect(await screen.findByText("PENDING")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "승인" }));
    expect(await screen.findByText("EXECUTED")).toBeInTheDocument();
    expect(screen.getByText("Gmail message sent: m1")).toBeInTheDocument();
    expect(fetchMock.mock.calls.some(([url]) => String(url) === "/api/approvals/a1/approve")).toBe(true);
  });

  it("shows Scheduler debug information returned by the Agent",async()=>{
    mockFetch({message:"등록했습니다.",toolCalls:[],toolResults:[],approvalRequired:false,model:"test",executionTimeMs:2,requestId:"r",sessionId:"s",schedule:{id:"sch-1",title:"Daily digest",scheduleType:"recurring",timezone:"Asia/Seoul",status:"scheduled",nextRunAt:"2026-08-12T23:00:00.000Z"}});
    render(<App/>);fireEvent.change(screen.getByRole("textbox",{name:"Agent command"}),{target:{value:"매일 알려줘"}});fireEvent.click(screen.getByRole("button",{name:/명령 보내기/}));
    expect(await screen.findByText("Daily digest")).toBeInTheDocument();expect(screen.getByText("recurring · scheduled")).toBeInTheDocument();expect(screen.getByText(/Asia\/Seoul/)).toBeInTheDocument();
  });

  it("displays network errors in the debug panel", async () => {
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new TypeError("Failed to fetch"));
    render(<App />);

    fireEvent.change(screen.getByRole("textbox", { name: "Agent command" }), { target: { value: "안녕" } });
    fireEvent.click(screen.getByRole("button", { name: /명령 보내기/ }));

    await waitFor(() => expect(screen.getByRole("alert")).toHaveTextContent("Jarvis API에 연결할 수 없습니다."));
  });

  it("displays an HTTP error when the local API proxy is unavailable", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation((input) => {
      if (String(input).includes("/api/calls")) return json({ calls: [] });
      return Promise.resolve(new Response(null, { status: 502 }));
    });
    render(<App />);

    fireEvent.change(screen.getByRole("textbox", { name: "Agent command" }), { target: { value: "안녕" } });
    fireEvent.click(screen.getByRole("button", { name: /명령 보내기/ }));

    await waitFor(() => {
      expect(screen.getByRole("alert")).toHaveTextContent("Jarvis API 요청이 실패했습니다 (502).");
      expect(screen.getByRole("alert")).toHaveTextContent("HTTP 502");
    });
  });

  it("shows a call report banner without mixing it into the conversation", async () => {
    vi.spyOn(globalThis, "fetch").mockImplementation((input) => {
      const url = String(input);
      if (url.endsWith("/api/calls")) {
        return Promise.resolve(Response.json({
          calls: [{
            id: "call-1",
            status: "completed",
            caller: { name: "unknown", phoneNumber: "01011112222" },
            startedAt: "2026-08-24T09:52:59.000Z",
            endedAt: "2026-08-24T09:53:21.000Z",
            summary: "택배 도착 안내",
            hasAudio: true,
            updatedAt: "2026-08-24T09:53:22.000Z",
          }],
        }));
      }
      if (url.includes("/api/calls/call-1")) {
        return Promise.resolve(Response.json({
          id: "call-1",
          status: "completed",
          caller: { name: "unknown", phoneNumber: "01011112222" },
          startedAt: "2026-08-24T09:52:59.000Z",
          endedAt: "2026-08-24T09:53:21.000Z",
          summary: "택배 도착 안내",
          hasAudio: true,
          updatedAt: "2026-08-24T09:53:22.000Z",
          transcript: [{ role: "caller", text: "택배 왔습니다" }],
          audioPath: "/api/calls/call-1/audio",
        }));
      }
      return Promise.resolve(Response.json({
        message: "채팅 응답", toolCalls: [], approvalRequired: false, model: "test", executionTimeMs: 1,
        requestId: "r1", sessionId: "s1", memory: { profileCount: 0, longTermMemoryCount: 0, conversationMessageCount: 0 },
      }));
    });
    render(<App />);
    expect(await screen.findByText("수신 전화")).toBeInTheDocument();
    expect(screen.getByText("01011112222")).toBeInTheDocument();
    expect(screen.getByText("택배 도착 안내")).toBeInTheDocument();
    expect(screen.queryByText("채팅 응답")).not.toBeInTheDocument();
  });

  it("disables STT when the browser does not expose speech recognition", () => {
    render(<App />);
    expect(screen.getByRole("button", { name: "마이크 입력" })).toBeDisabled();
    expect(screen.getByText("이 브라우저는 STT를 지원하지 않습니다.")).toBeInTheDocument();
  });
});
