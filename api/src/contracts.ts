export interface AgentMessageRequest {
  message: string;
  sessionId?: string;
}

export interface AgentMessageResponse {
  message: string;
  toolCalls: import("./tools/types").ToolCallDebug[];
  toolResults: import("./tools/types").ToolResultDebug[];
  approvalRequired: boolean;
  approval?: import("./approval/approval-repository").Approval;
  schedule?: import("./scheduler/types").JarvisSchedule;
  model: string;
  executionTimeMs: number;
  requestId: string;
  sessionId: string;
  memory: {
    savedMemoryId?: string;
    profileCount: number;
    longTermMemoryCount: number;
    conversationMessageCount: number;
  };
}

export type MessageRole = "user" | "assistant" | "system" | "tool";
export type MemorySource = "user" | "agent" | "system";
export interface ConversationMessage { messageId: string; sessionId: string; role: MessageRole; content: string; model: string | null; toolCalls: unknown; toolResult: unknown; createdAt: string }
export interface ConversationSummary { sessionId: string; createdAt: string; updatedAt: string; messageCount: number }
export interface ProfileMemory { id: string; type: "profile"; key: string; value: string; source: MemorySource; createdAt: string; updatedAt: string }
export interface LongTermMemory { id: string; type: "long_term"; content: string; category: string; source: MemorySource; createdAt: string; updatedAt: string }
export type CreateMemoryInput =
  | { type: "profile"; key: string; value: string; source: MemorySource }
  | { type: "long_term"; content: string; category: string; source: MemorySource };
export interface UpdateMemoryInput { value?: string; content?: string; category?: string; source?: MemorySource }

export interface AgentStateSnapshot {
  requestCount: number;
  lastRequestAt: string | null;
  sqliteConnected: boolean;
}
