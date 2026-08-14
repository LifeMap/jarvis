import { describe, expect, it, vi } from "vitest";
import { WorkersAiModelProvider } from "../src/llm/workers-ai-provider";

describe("WorkersAiModelProvider", () => {
  it("generates text through the Workers AI binding", async () => {
    const run = vi.fn().mockResolvedValue({ response: "Workers AI response" });
    const provider = new WorkersAiModelProvider({ run }, "@cf/test/model");
    await expect(provider.generate({ systemPrompt: "help", messages: [{ role: "user", content: "hello" }] }))
      .resolves.toEqual({ text: "Workers AI response", model: "@cf/test/model" });
    expect(run).toHaveBeenCalledWith("@cf/test/model", expect.objectContaining({ messages: expect.any(Array) }));
  });

  it("maps function calls and continues with a structured tool result", async () => {
    const run = vi.fn()
      .mockResolvedValueOnce({ tool_calls: [{ name: "web_search_search", arguments: { query: "Cloudflare" } }] })
      .mockResolvedValueOnce({ response: "검색 결과 요약" });
    const provider = new WorkersAiModelProvider({ run }, "@cf/test/model");
    const request = { systemPrompt: "help", messages: [{ role: "user" as const, content: "검색해줘" }] };
    const selected = await provider.selectTool(request, [{ name: "web_search.search", description: "search", inputSchema: { type: "object" } }]);
    expect(selected).toMatchObject({ name: "web_search.search", arguments: { query: "Cloudflare" } });
    await expect(provider.generateWithToolResult(request, selected!, { success: true, data: [] }))
      .resolves.toEqual({ text: "검색 결과 요약", model: "@cf/test/model" });
    expect(run).toHaveBeenCalledTimes(2);
  });

  it.each([
    ["gmail_search_messages", "gmail.search_messages", { query: "is:unread newer_than:1d", maxResults: 1 }],
    ["google_calendar_search_events", "google_calendar.search_events", {
      timeMin: "2026-08-15T12:00:00+09:00", timeMax: "2026-08-16T00:00:00+09:00", timezone: "Asia/Seoul",
    }],
  ])("preserves structured parameters for %s", async (providerName, jarvisName, arguments_) => {
    const run = vi.fn().mockResolvedValue({ tool_calls: [{ name: providerName, arguments: arguments_ }] });
    const provider = new WorkersAiModelProvider({ run }, "@cf/qwen/qwen3-30b-a3b-fp8");
    const selected = await provider.selectTool(
      { systemPrompt: "help", messages: [{ role: "user", content: "도구를 사용해줘" }] },
      [{ name: jarvisName, description: "read-only tool", inputSchema: { type: "object" } }],
    );

    expect(selected).toMatchObject({ name: jarvisName, arguments: arguments_ });
  });

  it("does not invent a Tool call when Workers AI returns only a direct response", async () => {
    const provider = new WorkersAiModelProvider({ run: vi.fn().mockResolvedValue({ response: "직접 답변" }) }, "@cf/qwen/qwen3-30b-a3b-fp8");
    await expect(provider.selectTool(
      { systemPrompt: "help", messages: [{ role: "user", content: "안녕" }] },
      [{ name: "gmail.search_messages", description: "read mail", inputSchema: { type: "object" } }],
    )).resolves.toBeNull();
  });

  it("contains binding failures as Model Provider errors", async () => {
    const provider = new WorkersAiModelProvider({ run: vi.fn().mockRejectedValue(new Error("binding failed")) }, "@cf/test/model");
    await expect(provider.generate({ systemPrompt: "help", messages: [{ role: "user", content: "hello" }] }))
      .rejects.toThrow("Workers AI provider 호출이 실패했습니다.");
  });
});
