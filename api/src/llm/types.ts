export interface LlmRequest {
  systemPrompt: string;
  messages: LlmMessage[];
}

export interface LlmMessage { role: "user" | "assistant"; content: string }

export interface LlmToolDefinition {
  name: string;
  description: string;
  inputSchema: Record<string, unknown>;
}

export interface LlmToolCall {
  id: string;
  name: string;
  arguments: Record<string, unknown>;
  continuation?: unknown;
}

export interface LlmResponse {
  text: string;
  model: string;
}

export interface LlmProvider {
  generate(request: LlmRequest): Promise<LlmResponse>;
  selectTool(request: LlmRequest, tools: LlmToolDefinition[]): Promise<LlmToolCall | null>;
  generateWithToolResult(request: LlmRequest, call: LlmToolCall, result: unknown): Promise<LlmResponse>;
}

export class LlmProviderError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = "LlmProviderError";
  }
}
