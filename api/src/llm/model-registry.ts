import type { Env } from "../env";
import type { ModelProviderId } from "./types";

export const DEFAULT_MODEL_PROVIDER = "workers-ai" as const;
export const DEFAULT_WORKERS_AI_MODEL = "@cf/qwen/qwen3-30b-a3b-fp8";
export const DEFAULT_OPENAI_MODEL = "gpt-5-mini";

export interface ModelSelection { provider: ModelProviderId; model: string }
export interface RegisteredModel extends ModelSelection {
  enabled: boolean;
  displayName: string;
  capabilities: { toolCalling: boolean; structuredOutput: boolean };
  unavailableReason?: string;
}

export class ModelRegistry {
  constructor(readonly models: RegisteredModel[], readonly defaultModel: ModelSelection) {}

  list(): RegisteredModel[] { return this.models.map((model) => ({ ...model, capabilities: { ...model.capabilities } })); }
  get(provider: ModelProviderId, model: string): RegisteredModel | undefined {
    return this.models.find((candidate) => candidate.provider === provider && candidate.model === model);
  }
  defaultForProvider(provider: ModelProviderId): RegisteredModel | undefined {
    return this.models.find((model) => model.provider === provider && model.enabled)
      ?? this.models.find((model) => model.provider === provider);
  }
}

export function createModelRegistry(env: Env): ModelRegistry {
  const defaultProvider = parseProvider(env.DEFAULT_MODEL_PROVIDER ?? DEFAULT_MODEL_PROVIDER);
  const defaultModel = env.DEFAULT_MODEL ?? DEFAULT_WORKERS_AI_MODEL;
  const workersModel = env.WORKERS_AI_MODEL ?? DEFAULT_WORKERS_AI_MODEL;
  const openAiModel = env.OPENAI_MODEL ?? (env.LLM_PROVIDER === "openai" ? env.LLM_MODEL : DEFAULT_OPENAI_MODEL);
  const workersModels = [...new Set([DEFAULT_WORKERS_AI_MODEL, workersModel])];
  const models: RegisteredModel[] = [
    ...workersModels.map((model): RegisteredModel => ({
      provider: "workers-ai", model, enabled: Boolean(env.AI),
      displayName: model === DEFAULT_WORKERS_AI_MODEL ? "Workers AI · Qwen3 30B A3B FP8" : `Workers AI · ${model}`,
      capabilities: { toolCalling: true, structuredOutput: true },
      ...(!env.AI ? { unavailableReason: "Workers AI binding(AI)이 설정되지 않았습니다." } : {}),
    })),
    {
      provider: "openai", model: openAiModel, enabled: Boolean(env.OPENAI_API_KEY),
      displayName: `OpenAI · ${openAiModel}`,
      capabilities: { toolCalling: true, structuredOutput: true },
      ...(!env.OPENAI_API_KEY ? { unavailableReason: "OPENAI_API_KEY Secret이 설정되지 않았습니다." } : {}),
    },
  ];
  if (defaultProvider === "test" || env.LLM_PROVIDER === "test") {
    models.push({
      provider: "test", model: env.LLM_MODEL, enabled: true, displayName: `Test · ${env.LLM_MODEL}`,
      capabilities: { toolCalling: true, structuredOutput: true },
    });
  }
  return new ModelRegistry(models, { provider: defaultProvider, model: defaultModel });
}

function parseProvider(value: string): ModelProviderId {
  if (value === "workers-ai" || value === "openai" || value === "test") return value;
  throw new Error(`DEFAULT_MODEL_PROVIDER 설정이 올바르지 않습니다: ${value}`);
}
