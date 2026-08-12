import type { AgentMessageResponse, Approval, StoredConversationMessage } from "../types/agent";

const DEFAULT_AGENT_API_URL = "/api/agent/message";

interface ErrorPayload {
  error?: string;
  detail?: string;
}

export async function resolveApproval(id: string, action: "approve" | "reject"): Promise<Approval> {
  const agentUrl = import.meta.env.VITE_AGENT_API_URL || DEFAULT_AGENT_API_URL;
  const url = agentUrl.replace(/\/agent\/message$/, `/approvals/${encodeURIComponent(id)}/${action}`);
  let response: Response;
  try { response = await fetch(url, { method: "POST", headers: { "content-type": "application/json" } }); }
  catch (error) { throw new AgentApiError("Approval API에 연결할 수 없습니다.", undefined, errorMessage(error)); }
  const payload = await readPayload(response);
  if (!response.ok) throw new AgentApiError(payload.error ?? `Approval 처리가 실패했습니다 (${response.status}).`, response.status, payload.detail);
  const approval = payload.approval as Approval | undefined;
  if (!approval?.approvalId) throw new AgentApiError("Approval API 응답 형식이 올바르지 않습니다.");
  return approval;
}

export class AgentApiError extends Error {
  constructor(
    message: string,
    readonly status?: number,
    readonly detail?: string,
  ) {
    super(message);
    this.name = "AgentApiError";
  }
}

export async function sendAgentMessage(
  message: string,
  sessionId: string,
  options?: { signal?: AbortSignal },
): Promise<AgentMessageResponse> {
  const apiUrl = import.meta.env.VITE_AGENT_API_URL || DEFAULT_AGENT_API_URL;
  let response: Response;

  try {
    response = await fetch(apiUrl, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ message, sessionId }),
      ...(options?.signal ? { signal: options.signal } : {}),
    });
  } catch (error) {
    throw new AgentApiError("Jarvis API에 연결할 수 없습니다.", undefined, errorMessage(error));
  }

  const payload = await readPayload(response);
  if (!response.ok) {
    throw new AgentApiError(
      payload.error ?? `Jarvis API 요청이 실패했습니다 (${response.status}).`,
      response.status,
      payload.detail,
    );
  }

  if (typeof payload.message !== "string") {
    throw new AgentApiError("Jarvis API 응답 형식이 올바르지 않습니다.");
  }
  return payload as unknown as AgentMessageResponse;
}

export async function getConversation(sessionId: string): Promise<StoredConversationMessage[]> {
  const agentUrl = import.meta.env.VITE_AGENT_API_URL || DEFAULT_AGENT_API_URL;
  const conversationUrl = agentUrl.replace(/\/agent\/message$/, `/conversations/${encodeURIComponent(sessionId)}`);
  try {
    const response = await fetch(conversationUrl, { headers: { accept: "application/json" } });
    if (response.status === 404) return [];
    const payload = await readPayload(response);
    if (!response.ok) throw new AgentApiError(payload.error ?? `Conversation 조회가 실패했습니다 (${response.status}).`, response.status, payload.detail);
    return Array.isArray(payload.messages) ? payload.messages as StoredConversationMessage[] : [];
  } catch (error) {
    if (error instanceof AgentApiError) throw error;
    throw new AgentApiError("저장된 Conversation을 불러올 수 없습니다.", undefined, errorMessage(error));
  }
}

async function readPayload(response: Response): Promise<ErrorPayload & Record<string, unknown>> {
  try {
    return (await response.json()) as ErrorPayload & Record<string, unknown>;
  } catch {
    if (!response.ok) return {};
    throw new AgentApiError("Jarvis API가 JSON이 아닌 응답을 반환했습니다.", response.status);
  }
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : "알 수 없는 네트워크 오류";
}
