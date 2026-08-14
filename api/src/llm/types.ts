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

export type ModelProviderId = "openai" | "test";

export interface ModelProvider {
  readonly providerId: ModelProviderId;
  readonly modelId: string;
  generate(request: LlmRequest): Promise<LlmResponse>;
  selectTool(request: LlmRequest, tools: LlmToolDefinition[]): Promise<LlmToolCall | null>;
  generateWithToolResult(request: LlmRequest, call: LlmToolCall, result: unknown): Promise<LlmResponse>;
}

// Backward-compatible domain name for existing LLM call sites.
export type LlmProvider = ModelProvider;

export class LlmProviderError extends Error {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = "LlmProviderError";
  }
}
