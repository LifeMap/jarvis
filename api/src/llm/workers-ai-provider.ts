import type { WorkersAiBinding } from "../env";
import type { LlmProvider, LlmRequest, LlmResponse, LlmToolCall, LlmToolDefinition } from "./types";
import { LlmProviderError } from "./types";

interface WorkersAiToolCall {
  name?: string;
  arguments?: Record<string, unknown> | string;
  function?: { name?: string; arguments?: Record<string, unknown> | string };
}
interface WorkersAiResponse { response?: string; tool_calls?: WorkersAiToolCall[] }
interface WorkersAiContinuation { providerTools: Array<Record<string, unknown>>; providerCall: WorkersAiToolCall }

export class WorkersAiModelProvider implements LlmProvider {
  readonly providerId = "workers-ai" as const;
  constructor(private readonly ai: WorkersAiBinding, readonly modelId: string) {}

  async generate(request: LlmRequest): Promise<LlmResponse> {
    const payload = await this.run({ messages: toMessages(request) });
    if (!payload.response?.trim()) throw new LlmProviderError("Workers AI 응답에 텍스트가 없습니다.");
    return { text: payload.response.trim(), model: this.modelId };
  }

  async selectTool(request: LlmRequest, tools: LlmToolDefinition[]): Promise<LlmToolCall | null> {
    if (!tools.length) return null;
    const names = new Map(tools.map((tool) => [toProviderToolName(tool.name), tool.name]));
    if (names.size !== tools.length) throw new LlmProviderError("Workers AI Tool 이름 변환 결과가 중복됩니다.");
    const providerTools = tools.map((tool) => ({
      name: toProviderToolName(tool.name), description: tool.description, parameters: tool.inputSchema,
    }));
    const payload = await this.run({
      messages: toMessages(request, "Use a tool only when the user's request clearly requires that exact external capability. For ordinary conversation, answer directly and do not call a tool. Never infer email sending, replying, calendar changes, or deletion from generic words such as answer, reply, tell, or respond."),
      tools: providerTools,
    });
    const providerCall = payload.tool_calls?.[0];
    const providerName = providerCall?.function?.name ?? providerCall?.name;
    if (!providerCall || !providerName) return null;
    const name = names.get(providerName);
    if (!name) throw new LlmProviderError(`등록되지 않은 Tool이 선택되었습니다: ${providerName}`);
    return {
      id: crypto.randomUUID(), name, arguments: parseArguments(providerCall.function?.arguments ?? providerCall.arguments),
      continuation: { providerTools, providerCall } satisfies WorkersAiContinuation,
    };
  }

  async generateWithToolResult(request: LlmRequest, call: LlmToolCall, result: unknown): Promise<LlmResponse> {
    const continuation = call.continuation as WorkersAiContinuation | undefined;
    if (!continuation?.providerCall) throw new LlmProviderError("Tool 호출을 이어갈 Workers AI 정보가 없습니다.");
    const payload = await this.run({
      messages: [
        ...toMessages(request),
        { role: "assistant", content: JSON.stringify(continuation.providerCall) },
        { role: "tool", content: JSON.stringify(result) },
      ],
      tools: continuation.providerTools,
    });
    if (!payload.response?.trim()) throw new LlmProviderError("Workers AI Tool 결과 응답에 텍스트가 없습니다.");
    return { text: payload.response.trim(), model: this.modelId };
  }

  private async run(input: Record<string, unknown>): Promise<WorkersAiResponse> {
    try { return await this.ai.run(this.modelId, { max_tokens: 1024, ...input }) as WorkersAiResponse; }
    catch (error) { throw new LlmProviderError("Workers AI provider 호출이 실패했습니다.", { cause: error }); }
  }
}

function toMessages(request: LlmRequest, providerInstruction?: string): Array<{ role: string; content: string }> {
  return [{ role: "system", content: `${request.systemPrompt}${providerInstruction ? `\n\n${providerInstruction}` : ""}` }, ...request.messages];
}
function toProviderToolName(name: string): string { return name.replace(/[^a-zA-Z0-9_-]/g, "_"); }
function parseArguments(value: Record<string, unknown> | string | undefined): Record<string, unknown> {
  if (!value) return {};
  if (typeof value === "object") return value;
  try { return JSON.parse(value) as Record<string, unknown>; }
  catch (error) { throw new LlmProviderError("Workers AI Tool arguments가 올바른 JSON이 아닙니다.", { cause: error }); }
}
