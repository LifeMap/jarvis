import type { Env } from "../env";
import { OpenAiProvider } from "./openai-provider";
import { TestLlmProvider } from "./test-provider";
import type { ModelProvider } from "./types";
import { LlmProviderError } from "./types";

export function createModelProvider(env: Env): ModelProvider {
  switch (env.LLM_PROVIDER) {
    case "openai": {
      if (!env.OPENAI_API_KEY) {
        throw new LlmProviderError(
          "OPENAI_API_KEY Secret이 설정되지 않았습니다. `npx wrangler secret put OPENAI_API_KEY`로 등록하세요.",
        );
      }
      return new OpenAiProvider({
        apiKey: env.OPENAI_API_KEY,
        model: env.LLM_MODEL,
        ...(env.OPENAI_BASE_URL ? { baseUrl: env.OPENAI_BASE_URL } : {}),
      });
    }
    case "test":
      return new TestLlmProvider(env.TEST_LLM_RESPONSE ?? "Jarvis test response");
    default:
      throw new LlmProviderError(`지원하지 않는 LLM provider입니다: ${env.LLM_PROVIDER}`);
  }
}

// Keep the old export while callers migrate to the provider terminology.
export const createLlmProvider = createModelProvider;
