import { describe, expect, it, vi } from "vitest";
import type { Env } from "../src/env";
import { createModelProvider } from "../src/llm/provider-factory";
import { createToolProviders } from "../src/tools/provider-factory";
import { ToolRegistry } from "../src/tools/tool-registry";

describe("Provider factories", () => {
  it("identifies the configured Model Provider without invoking it", () => {
    const provider = createModelProvider({
      DEFAULT_MODEL_PROVIDER: "openai",
      DEFAULT_MODEL: "gpt-test",
      LLM_PROVIDER: "openai",
      LLM_MODEL: "gpt-test",
      OPENAI_API_KEY: "test-secret",
    } as Env);

    expect(provider.providerId).toBe("openai");
    expect(provider.modelId).toBe("gpt-test");
  });

  it("creates explicit API Tool Provider identities", () => {
    const providers = createToolProviders({
      SEARCH_PROVIDER: "brave",
      SEARCH_API_KEY: "brave-test-key",
      SEARCH_FALLBACK_PROVIDER: "serpapi",
      SERP_API_KEY: "serp-test-key",
    } as Env, { getAccessToken: vi.fn().mockResolvedValue("google-test-token") });
    const registry = new ToolRegistry(providers);

    expect(registry.provider("gmail.search_messages")).toEqual({ service: "gmail", implementation: "google-api" });
    expect(registry.provider("google_calendar.search_events")).toEqual({ service: "calendar", implementation: "google-api" });
    expect(registry.provider("web_search.search")).toEqual({
      service: "search",
      implementation: "brave-api",
      fallbackImplementation: "serpapi",
    });
  });

  it("marks search unavailable without inventing a runtime Provider", () => {
    const providers = createToolProviders({ SEARCH_PROVIDER: "none" } as Env, {
      getAccessToken: vi.fn().mockResolvedValue("google-test-token"),
    });

    expect(providers.search.identity).toEqual({ service: "search", implementation: "unavailable" });
  });
});
