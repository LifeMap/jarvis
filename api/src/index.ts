import type { AgentMessageRequest, CreateMemoryInput, MemorySource, UpdateMemoryInput } from "./contracts";
import type { Env } from "./env";
import type { ApprovalStatus } from "./approval/approval-repository";

export { PersonalAssistantAgent } from "./personal-assistant-agent";

const AGENT_NAME = "primary";

export default {
  async fetch(request, env): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/health") {
      return json({ status: "ok", service: "jarvis-api" });
    }

    if (request.method === "GET" && url.pathname === "/api/oauth/google/callback") {
      const code = url.searchParams.get("code");
      const state = url.searchParams.get("state");
      if (!code || !state) return json({ error: url.searchParams.get("error") ?? "Missing OAuth code or state" }, 400);
      try {
        const oauthAgent = env.PERSONAL_ASSISTANT_AGENT.getByName(AGENT_NAME);
        await oauthAgent.completeGoogleAuthorization(code, state);
        return new Response("Google account connected. You can close this window.", { headers: { "content-type": "text/plain; charset=utf-8" } });
      } catch (error) {
        return json({ error: "Google OAuth callback failed", detail: error instanceof Error ? error.message : "Unknown error" }, 400);
      }
    }

    if (!isAuthorized(request, env)) {
      return json({ error: "Unauthorized" }, 401, { "www-authenticate": "Bearer" });
    }

    const agent = env.PERSONAL_ASSISTANT_AGENT.getByName(AGENT_NAME);

    if (url.pathname === "/api/oauth/google/authorize" && request.method === "GET") {
      const redirectUri = `${url.origin}/api/oauth/google/callback`;
      try { return json({ authorizationUrl: await agent.googleAuthorizationUrl(redirectUri) }); }
      catch (error) { return json({ error: "Google OAuth is not configured", detail: error instanceof Error ? error.message : "Unknown error" }, 503); }
    }
    if (url.pathname === "/api/oauth/google/status" && request.method === "GET") {
      return json(await agent.googleConnectionStatus());
    }
    if (url.pathname === "/api/oauth/google/disconnect" && request.method === "POST") {
      return json({ disconnected: await agent.disconnectGoogle() });
    }
    if (url.pathname === "/api/tool-executions" && request.method === "GET") {
      return json({ executions: await agent.listToolExecutions() });
    }
    if (url.pathname === "/api/approvals" && request.method === "GET") {
      const status = url.searchParams.get("status");
      if (status && !isApprovalStatus(status)) return json({ error: "Invalid approval status" }, 400);
      return json({ approvals: await agent.listApprovals(status && isApprovalStatus(status) ? status : undefined) });
    }
    const approvalPath = matchApprovalPath(url.pathname);
    if (approvalPath) {
      if (!approvalPath.action && request.method === "GET") {
        const approval = await agent.getApproval(approvalPath.id);
        return approval ? json(approval) : json({ error: "Approval not found" }, 404);
      }
      if (approvalPath.action && request.method === "POST") {
        if (approvalPath.action === "approve") {
          const result = await agent.approveApproval(approvalPath.id) as unknown as ApprovalApiResult;
          if (result.ok) return json(result);
          return approvalError(result);
        }
        const result = await agent.rejectApproval(approvalPath.id) as unknown as ApprovalApiResult;
        if (result.ok) return json(result);
        return approvalError(result);
      }
      return json({ error: "Method not allowed" }, 405);
    }

    if (url.pathname === "/api/agent/message") {
      if (request.method !== "POST") return json({ error: "Method not allowed" }, 405, { allow: "POST" });
      return handleAgentMessage(request, agent);
    }

    if (url.pathname === "/api/memories") {
      if (request.method === "GET") return json(await agent.listMemories());
      if (request.method === "POST") return handleCreateMemory(request, agent);
      return json({ error: "Method not allowed" }, 405, { allow: "GET, POST" });
    }

    const memoryId = matchPath(url.pathname, "/api/memories/");
    if (memoryId) {
      if (request.method === "PATCH") return handleUpdateMemory(request, agent, memoryId);
      if (request.method === "DELETE") return (await agent.deleteMemory(memoryId)) ? json({ deleted: true }) : json({ error: "Memory not found" }, 404);
      return json({ error: "Method not allowed" }, 405, { allow: "PATCH, DELETE" });
    }

    if (url.pathname === "/api/conversations" && request.method === "GET") {
      return json({ conversations: await agent.listConversations() });
    }
    const sessionId = matchPath(url.pathname, "/api/conversations/");
    if (sessionId) {
      if (request.method === "GET") return json({ sessionId, messages: await agent.getConversation(sessionId) });
      if (request.method === "DELETE") return (await agent.deleteConversation(sessionId)) ? json({ deleted: true }) : json({ error: "Conversation not found" }, 404);
      return json({ error: "Method not allowed" }, 405, { allow: "GET, DELETE" });
    }

    return json({ error: "Not found" }, 404);
  },
} satisfies ExportedHandler<Env>;

type AgentStub = DurableObjectStub<import("./personal-assistant-agent").PersonalAssistantAgent>;

async function handleAgentMessage(request: Request, agent: AgentStub): Promise<Response> {

    let body: AgentMessageRequest;
    try {
      body = (await request.json()) as AgentMessageRequest;
    } catch {
      return json({ error: "Request body must be valid JSON" }, 400);
    }

    const message = typeof body.message === "string" ? body.message.trim() : "";
    if (!message || message.length > 10_000) {
      return json({ error: "message must be between 1 and 10000 characters" }, 400);
    }
    const sessionId = typeof body.sessionId === "string" && body.sessionId.trim() ? body.sessionId.trim() : "default";
    if (!isValidId(sessionId)) return json({ error: "sessionId must contain 1 to 128 safe characters" }, 400);

    try {
      return json(await agent.message(message, sessionId));
    } catch (error) {
      console.error("Agent request failed", error);
      return json(
        { error: "Agent request failed", detail: error instanceof Error ? error.message : "Unknown error" },
        502,
      );
    }
}

async function handleCreateMemory(request: Request, agent: AgentStub): Promise<Response> {
  const body = await readJson(request);
  const input = parseCreateMemory(body);
  if (!input) return json({ error: "Invalid memory payload" }, 400);
  return json(await agent.createMemory(input), 201);
}

async function handleUpdateMemory(request: Request, agent: AgentStub, id: string): Promise<Response> {
  const body = await readJson(request);
  if (!body || typeof body !== "object") return json({ error: "Invalid memory payload" }, 400);
  const input = body as UpdateMemoryInput;
  if (input.source !== undefined && !isMemorySource(input.source)) return json({ error: "Invalid memory source" }, 400);
  const updated = await agent.updateMemory(id, input);
  return updated ? json(updated) : json({ error: "Memory not found" }, 404);
}

async function readJson(request: Request): Promise<unknown> {
  try { return await request.json(); } catch { return null; }
}

function parseCreateMemory(value: unknown): CreateMemoryInput | null {
  if (!value || typeof value !== "object") return null;
  const body = value as Record<string, unknown>;
  const source = body.source ?? "user";
  if (!isMemorySource(source)) return null;
  if (body.type === "profile" && isText(body.key) && isText(body.value)) {
    return { type: "profile", key: body.key.trim(), value: body.value.trim(), source };
  }
  if (body.type === "long_term" && isText(body.content)) {
    return { type: "long_term", content: body.content.trim(), category: isText(body.category) ? body.category.trim() : "general", source };
  }
  return null;
}

function matchPath(pathname: string, prefix: string): string | null {
  if (!pathname.startsWith(prefix)) return null;
  const encoded = pathname.slice(prefix.length);
  if (!encoded || encoded.includes("/")) return null;
  try { return decodeURIComponent(encoded); } catch { return null; }
}

function matchApprovalPath(pathname: string): { id: string; action?: "approve" | "reject" } | null {
  const match = pathname.match(/^\/api\/approvals\/([^/]+)(?:\/(approve|reject))?$/);
  if (!match?.[1]) return null;
  try {
    const id = decodeURIComponent(match[1]);
    return match[2] ? { id, action: match[2] as "approve" | "reject" } : { id };
  } catch { return null; }
}

function isApprovalStatus(value: string): value is ApprovalStatus {
  return ["PENDING", "APPROVED", "REJECTED", "EXECUTED", "FAILED", "EXPIRED"].includes(value);
}

function isValidId(value: string): boolean { return value.length <= 128 && /^[A-Za-z0-9._:-]+$/.test(value); }
function isText(value: unknown): value is string { return typeof value === "string" && value.trim().length > 0 && value.length <= 10_000; }
function isMemorySource(value: unknown): value is MemorySource { return value === "user" || value === "agent" || value === "system"; }

function isAuthorized(request: Request, env: Env): boolean {
  if (!env.JARVIS_API_TOKEN) {
    console.error("JARVIS_API_TOKEN Secret is not configured");
    return false;
  }
  return request.headers.get("authorization") === `Bearer ${env.JARVIS_API_TOKEN}`;
}

function json(body: unknown, status = 200, headers?: Record<string, string>): Response {
  return Response.json(body, {
    status,
    headers: { "cache-control": "no-store", ...headers },
  });
}

function approvalError(result: { code: string; message: string; approval?: unknown }): Response {
  const status = result.code === "NOT_FOUND" ? 404 : result.code === "EXPIRED" ? 410 : 409;
  return json({ error: result.message, code: result.code, approval: result.approval }, status);
}
type ApprovalApiResult = { ok: true; approval: unknown } | { ok: false; code: string; message: string; approval?: unknown };
