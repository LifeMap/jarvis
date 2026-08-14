import type { LlmProvider, LlmRequest, LlmResponse, LlmToolCall, LlmToolDefinition } from "./types";
import { LlmProviderError } from "./types";

interface OpenAiResponse {
  id?: string;
  model?: string;
  output_text?: string;
  output?: Array<{
    type?: string;
    call_id?: string;
    name?: string;
    arguments?: string;
    content?: Array<{ type?: string; text?: string }>;
  }>;
  error?: { message?: string };
}

interface OpenAiToolContinuation {
  outputItem: NonNullable<OpenAiResponse["output"]>[number];
  tools: Array<Record<string, unknown>>;
  responseId?: string;
}

export interface OpenAiProviderOptions {
  apiKey: string;
  model: string;
  baseUrl?: string;
  fetch?: typeof globalThis.fetch;
}

export class OpenAiProvider implements LlmProvider {
  readonly providerId = "openai" as const;
  readonly #apiKey: string;
  readonly #model: string;
  readonly #baseUrl: string;
  readonly #fetch: typeof globalThis.fetch;

  constructor(options: OpenAiProviderOptions) {
    this.#apiKey = options.apiKey;
    this.#model = options.model;
    this.#baseUrl = (options.baseUrl ?? "https://api.openai.com/v1").replace(/\/$/, "");
    this.#fetch = options.fetch ?? ((input, init) => fetch(input, init));
  }

  get modelId(): string { return this.#model; }

  async generate(request: LlmRequest): Promise<LlmResponse> {
    const payload = await this.request(request);
    const text = extractText(payload);
    if (!text) throw new LlmProviderError("LLM 응답에 텍스트가 없습니다.");
    return { text, model: payload.model ?? this.#model };
  }

  async selectTool(request: LlmRequest, tools: LlmToolDefinition[]): Promise<LlmToolCall | null> {
    if (tools.length === 0) return null;
    const names = new Map(tools.map((tool) => [toProviderToolName(tool.name), tool.name]));
    if (names.size !== tools.length) throw new LlmProviderError("OpenAI Tool 이름 변환 결과가 중복됩니다.");
    const providerTools = tools.map((tool) => ({
      type: "function",
      name: toProviderToolName(tool.name),
      description: tool.description,
      parameters: tool.inputSchema,
      strict: false,
    }));
    const payload = await this.request(request, {
      tools: providerTools,
      tool_choice: "auto",
    });
    const call = payload.output?.find((item) => item.type === "function_call" && item.name);
    if (!call?.name) return null;
    const originalName=names.get(call.name);
    if(!originalName)throw new LlmProviderError(`등록되지 않은 Tool이 선택되었습니다: ${call.name}`);
    try {
      return {
        id: call.call_id ?? crypto.randomUUID(),
        name: originalName,
        arguments: JSON.parse(call.arguments ?? "{}") as Record<string, unknown>,
        continuation: { outputItem: call, tools: providerTools, ...(payload.id?{responseId:payload.id}:{}) } satisfies OpenAiToolContinuation,
      };
    } catch (error) {
      throw new LlmProviderError("LLM Tool arguments가 올바른 JSON이 아닙니다.", { cause: error });
    }
  }

  async generateWithToolResult(request: LlmRequest, call: LlmToolCall, result: unknown): Promise<LlmResponse> {
    const continuation = call.continuation as OpenAiToolContinuation | undefined;
    if (!continuation?.outputItem) {
      throw new LlmProviderError("Tool 호출을 이어갈 provider 정보가 없습니다.");
    }
    const toolOutput={ type: "function_call_output", call_id: call.id, output: JSON.stringify(result) };
    const extra=continuation.responseId
      ?{input:[toolOutput],tools:continuation.tools,previous_response_id:continuation.responseId}
      :{input:[...request.messages.map((message)=>({role:message.role,content:message.content})),continuation.outputItem,toolOutput],tools:continuation.tools};
    const payload = await this.request(request, extra);
    const text = extractText(payload);
    if (!text) throw new LlmProviderError("LLM 응답에 텍스트가 없습니다.");
    return { text, model: payload.model ?? this.#model };
  }

  private async request(request: LlmRequest, extra: Record<string, unknown> = {}): Promise<OpenAiResponse> {
    let response: Response;
    try {
      response = await this.#fetch(`${this.#baseUrl}/responses`, {
        method: "POST",
        headers: {
          authorization: `Bearer ${this.#apiKey}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          model: this.#model,
          instructions: request.systemPrompt,
          input: request.messages.map((message) => ({ role: message.role, content: message.content })),
          ...extra,
        }),
      });
    } catch (error) {
      throw new LlmProviderError("LLM provider에 연결할 수 없습니다.", { cause: error });
    }

    const payload = await parseJson(response);
    if (!response.ok) {
      throw new LlmProviderError(
        `LLM 요청이 실패했습니다 (${response.status}): ${payload.error?.message ?? "알 수 없는 오류"}`,
      );
    }

    return payload;
  }
}

function toProviderToolName(name:string):string{return name.replace(/[^a-zA-Z0-9_-]/g,"_")}

async function parseJson(response: Response): Promise<OpenAiResponse> {
  try {
    return (await response.json()) as OpenAiResponse;
  } catch (error) {
    throw new LlmProviderError("LLM provider가 올바르지 않은 JSON을 반환했습니다.", { cause: error });
  }
}

function extractText(payload: OpenAiResponse): string | undefined {
  if (payload.output_text?.trim()) return payload.output_text.trim();

  const parts = payload.output
    ?.flatMap((item) => item.content ?? [])
    .filter((content) => content.type === "output_text" && content.text)
    .map((content) => content.text?.trim())
    .filter((text): text is string => Boolean(text));

  return parts?.join("\n") || undefined;
}
