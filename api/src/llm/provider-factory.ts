import type { Env } from "../env";
import { OpenAiProvider } from "./openai-provider";
import { TestLlmProvider } from "./test-provider";
import type { ModelProvider } from "./types";
import { LlmProviderError } from "./types";
import { createModelRegistry, type ModelSelection } from "./model-registry";
import { WorkersAiModelProvider } from "./workers-ai-provider";

export function createModelProvider(env: Env, selection: ModelSelection = defaultSelection(env)): ModelProvider {
  switch (selection.provider) {
    case "workers-ai": {
      if (!env.AI) throw new LlmProviderError("Workers AI binding(AI)이 설정되지 않았습니다.");
      return new WorkersAiModelProvider(env.AI, selection.model);
    }
    case "openai": {
      if (!env.OPENAI_API_KEY) {
        throw new LlmProviderError(
          "OPENAI_API_KEY Secret이 설정되지 않았습니다. `npx wrangler secret put OPENAI_API_KEY`로 등록하세요.",
        );
      }
      return new OpenAiProvider({
        apiKey: env.OPENAI_API_KEY,
        model: selection.model,
        ...(env.OPENAI_BASE_URL ? { baseUrl: env.OPENAI_BASE_URL } : {}),
      });
    }
    case "test":
      return new TestLlmProvider(env.TEST_LLM_RESPONSE ?? "Jarvis test response", selection.model);
    default:
      throw new LlmProviderError(`지원하지 않는 Model Provider입니다: ${String(selection.provider)}`);
  }
}

// Keep the old export while callers migrate to the provider terminology.
export const createLlmProvider = createModelProvider;

function defaultSelection(env: Env): ModelSelection {
  return createModelRegistry(env).defaultModel;
}
