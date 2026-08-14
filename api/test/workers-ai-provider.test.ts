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

  it("contains binding failures as Model Provider errors", async () => {
    const provider = new WorkersAiModelProvider({ run: vi.fn().mockRejectedValue(new Error("binding failed")) }, "@cf/test/model");
    await expect(provider.generate({ systemPrompt: "help", messages: [{ role: "user", content: "hello" }] }))
      .rejects.toThrow("Workers AI provider 호출이 실패했습니다.");
  });
});
