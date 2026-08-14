import { describe, expect, it, vi } from "vitest";
import { FallbackModelProvider } from "../src/llm/fallback-model-provider";
import type { LlmRequest, ModelProvider } from "../src/llm/types";
import { classifyProviderFailure } from "../src/runtime/provider-health";
import { parseReliabilityManagementIntent } from "../src/runtime/reliability-management-tools";
import { ToolRegistry } from "../src/tools/tool-registry";
import type { ToolProviderSet } from "../src/tools/provider-types";

const request: LlmRequest = { systemPrompt: "test", messages: [{ role: "user", content: "hello" }] };

describe("provider failure classification", () => {
  it("permits transient failures and rejects caller/auth failures", () => {
    expect(classifyProviderFailure(new Error("HTTP 429 rate limit")).fallbackEligible).toBe(true);
    expect(classifyProviderFailure(new Error("fetch failed network unavailable")).fallbackEligible).toBe(true);
    expect(classifyProviderFailure(new Error("HTTP 401 unauthorized")).fallbackEligible).toBe(false);
    expect(classifyProviderFailure(new Error("HTTP 400 invalid arguments")).fallbackEligible).toBe(false);
  });

  it("routes explicit reliability commands but does not mutate on discussion", () => {
    expect(parseReliabilityManagementIntent("Provider 상태 확인해줘")?.toolName).toBe("provider_health.check");
    expect(parseReliabilityManagementIntent("OpenAI가 실패하면 Workers AI를 fallback으로 사용해")).toMatchObject({ toolName: "fallback.set", arguments: { target: "model", provider: "workers-ai" } });
    expect(parseReliabilityManagementIntent("Search fallback을 제거해")?.toolName).toBe("fallback.remove");
    expect(parseReliabilityManagementIntent("OpenAI fallback이 좋을까?")).toBeNull();
  });
});

describe("model fallback", () => {
  it("uses fallback once while exposing the primary as active", async () => {
    const primary = provider("openai", async () => { throw new Error("HTTP 503 server error"); });
    const secondary = provider("workers-ai", async () => ({ text: "fallback", model: "qwen" }));
    const events = { event: vi.fn() };
    const health = { markSuccess: vi.fn(), markFailure: vi.fn() };
    const wrapped = new FallbackModelProvider(primary, secondary, events as never, health as never);
    await expect(wrapped.generate(request)).resolves.toMatchObject({ text: "fallback" });
    await expect(wrapped.generate(request)).resolves.toMatchObject({ text: "fallback" });
    expect(wrapped.providerId).toBe("openai");
    expect(events.event).toHaveBeenCalledTimes(2);
  });

  it("does not fallback on authentication errors", async () => {
    const primary = provider("openai", async () => { throw new Error("HTTP 401 unauthorized"); });
    const secondaryGenerate = vi.fn(async () => ({ text: "fallback", model: "qwen" }));
    const wrapped = new FallbackModelProvider(primary, provider("workers-ai", secondaryGenerate), { event: vi.fn() } as never, { markSuccess: vi.fn(), markFailure: vi.fn() } as never);
    await expect(wrapped.generate(request)).rejects.toThrow("401");
    expect(secondaryGenerate).not.toHaveBeenCalled();
  });
});

describe("tool fallback safety", () => {
  it("falls back for a read-only tool and tries primary again on the next call", async () => {
    const primarySearch = vi.fn(async () => { throw new Error("HTTP 429 rate limit"); });
    const fallbackSearch = vi.fn(async () => [{ title: "ok", url: "https://example.com", snippet: "ok", source: "test" }]);
    const events = { event: vi.fn() };
    const registry = new ToolRegistry(toolProviders(primarySearch), undefined, [], {
      providers: toolProviders(fallbackSearch), services: new Set(["search"]),
      configuration: events as never, health: { markSuccess: vi.fn(), markFailure: vi.fn() } as never,
    });
    const first = await registry.execute("web_search.search", { query: "Jarvis" }, { timezone: "UTC" });
    const second = await registry.execute("web_search.search", { query: "Jarvis" }, { timezone: "UTC" });
    expect(first.fallbackUsed).toBe(true);
    expect(second.fallbackUsed).toBe(true);
    expect(primarySearch).toHaveBeenCalledTimes(2);
    expect(fallbackSearch).toHaveBeenCalledTimes(2);
    expect(events.event).toHaveBeenCalledTimes(2);
  });

  it("never replays a write tool through fallback", async () => {
    const send = vi.fn(async () => { throw new Error("timeout after send"); });
    const fallbackSend = vi.fn(async () => ({ id: "duplicate" }));
    const registry = new ToolRegistry(toolProviders(vi.fn(), send), undefined, [], {
      providers: toolProviders(vi.fn(), fallbackSend), services: new Set(["gmail"]),
      configuration: { event: vi.fn() } as never, health: { markSuccess: vi.fn(), markFailure: vi.fn() } as never,
    });
    await expect(registry.execute("gmail.send", { to: "a@example.com", subject: "s", body: "b" }, { timezone: "UTC" }, { approvalId: "a", toolName: "gmail.send" })).rejects.toThrow("Gmail write failed");
    expect(fallbackSend).not.toHaveBeenCalled();
  });
});

function provider(providerId: "openai" | "workers-ai", generate: ModelProvider["generate"]): ModelProvider {
  return { providerId, modelId: providerId === "openai" ? "gpt" : "qwen", generate, selectTool: async () => null, generateWithToolResult: async req => generate(req) };
}

function toolProviders(search: (...args: unknown[]) => Promise<unknown>, send = vi.fn(async () => ({ id: "sent" }))): ToolProviderSet {
  return {
    gmail: { identity: { service: "gmail", implementation: "gmail-api" }, client: { searchMessages: async () => [], getMessage: async () => { throw new Error("unused"); }, sendMessage: send, replyMessage: async () => ({ id: "reply" }) } as never },
    calendar: { identity: { service: "calendar", implementation: "google-calendar-api" }, client: { searchEvents: async () => [], createEvent: async () => ({}), updateEvent: async () => ({}), deleteEvent: async () => undefined } as never },
    search: { identity: { service: "search", implementation: "brave-api" }, provider: { search } as never },
  };
}
