export interface ToolContext {
  timezone: string;
}

export type ToolPolicy = "AUTO" | "APPROVAL_REQUIRED";

export interface ToolDefinition<TResult = unknown> {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
  policy: ToolPolicy;
  requiresApproval: boolean;
  execute(input: Record<string, unknown>, context: ToolContext): Promise<TResult>;
  summarize(result: TResult): string;
}

export interface ToolCallDebug {
  id: string;
  name: string;
  input: Record<string, unknown>;
  requiresApproval: boolean;
  approvalId?: string;
}


export interface ToolExecutionAuthorization {
  approvalId: string;
  toolName: string;
}

export interface ToolResultDebug {
  toolCallId: string;
  name: string;
  success: boolean;
  durationMs: number;
  summary: string;
  error?: string;
}

export class ToolError extends Error {
  constructor(
    message: string,
    readonly userMessage: string,
    options?: ErrorOptions,
  ) {
    super(message, options);
    this.name = "ToolError";
  }
}


export class ToolPolicyError extends Error {
  constructor(readonly code: "APPROVAL_REQUIRED" | "POLICY_MISMATCH", message: string) {
    super(message);
    this.name = "ToolPolicyError";
  }
}
