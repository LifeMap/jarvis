export type ApprovalStatus = "PENDING" | "APPROVED" | "REJECTED" | "EXECUTED" | "FAILED" | "EXPIRED";
export interface Approval {
  approvalId: string; conversationId: string; requestId: string; toolCallId: string; toolName: string;
  toolArguments: Record<string, unknown>; policy: "APPROVAL_REQUIRED"; status: ApprovalStatus;
  requestedAt: string; expiresAt: string | null; resolvedAt: string | null; executedAt: string | null;
  resultSummary: string | null; error: string | null; executionId: string | null;
}
export interface ToolCallDebug { id: string; name: string; input: Record<string, unknown>; requiresApproval: boolean; approvalId?: string }
export interface ToolResultDebug { toolCallId: string; name: string; success: boolean; durationMs: number; summary: string; error?: string }

export interface AgentMessageResponse {
  message: string;
  toolCalls: ToolCallDebug[];
  toolResults?: ToolResultDebug[];
  approvalRequired: boolean;
  approval?: Approval;
  schedule?: { id:string; title:string; scheduleType:"one_time"|"recurring"; timezone:string; status:string; nextRunAt:string|null };
  model: string;
  executionTimeMs: number;
  requestId: string;
  sessionId: string;
  memory?: {
    savedMemoryId?: string;
    profileCount: number;
    longTermMemoryCount: number;
    conversationMessageCount: number;
  };
}

export interface ConversationMessage {
  id: string;
  role: "user" | "assistant";
  content: string;
}

export interface StoredConversationMessage {
  messageId: string;
  sessionId: string;
  role: "user" | "assistant" | "system" | "tool";
  content: string;
}

export interface DebugSnapshot {
  response?: AgentMessageResponse;
  roundTripTimeMs?: number;
  error?: {
    message: string;
    detail?: string;
    status?: number;
  };
}
