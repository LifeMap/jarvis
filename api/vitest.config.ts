import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        bindings: {
          JARVIS_API_TOKEN: "test-token",
          LLM_PROVIDER: "test",
          LLM_MODEL: "test-model",
          DEFAULT_MODEL_PROVIDER: "test",
          DEFAULT_MODEL: "test-model",
          TEST_LLM_RESPONSE: "안녕하세요. Jarvis 테스트 응답입니다.",
          SEARCH_API_KEY: "test-brave-key",
          SERP_API_KEY: "test-serp-key",
        },
      },
    }),
  ],
});
