import { describe, expect, it, vi } from "vitest";
import { OpenAiProvider } from "../src/llm/openai-provider";

describe("OpenAiProvider", () => {
  it("maps the provider response into the common LLM contract", async () => {
    const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(
      Response.json({
        model: "gpt-test",
        output: [{ content: [{ type: "output_text", text: "Provider response" }] }],
      }),
    );
    const provider = new OpenAiProvider({
      apiKey: "secret",
      model: "gpt-test",
      fetch: fetchMock,
    });

    await expect(
      provider.generate({ messages: [{ role: "user", content: "hello" }], systemPrompt: "be helpful" }),
    ).resolves.toEqual({ text: "Provider response", model: "gpt-test" });
    expect(fetchMock).toHaveBeenCalledOnce();
  });

  it("maps Responses API function calls into the common Tool contract", async () => {
    const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(Response.json({
      model: "gpt-test",
      output: [{ type: "function_call", call_id: "call-1", name: "web_search_search", arguments: "{\"query\":\"Cloudflare Agents\"}" }],
    }));
    const provider = new OpenAiProvider({ apiKey: "secret", model: "gpt-test", fetch: fetchMock });
    const selected = await provider.selectTool(
      { messages: [{ role: "user", content: "최신 내용 검색" }], systemPrompt: "be helpful" },
      [{ name: "web_search.search", description: "search", inputSchema: { type: "object" } }],
    );
    expect(selected).toMatchObject({ id: "call-1", name: "web_search.search", arguments: { query: "Cloudflare Agents" } });
    const sent=JSON.parse(String(fetchMock.mock.calls[0]?.[1]?.body)) as {tools:Array<{name:string}>};
    expect(sent.tools[0]?.name).toBe("web_search_search");
  });

  it("continues a Responses API function call with its call_id and structured output", async () => {
    const fetchMock = vi.fn<typeof fetch>()
      .mockResolvedValueOnce(Response.json({
        id: "resp-1",
        output: [{ type: "function_call", call_id: "call-2", name: "web_search_search", arguments: "{\"query\":\"Cloudflare\"}" }],
      }))
      .mockResolvedValueOnce(Response.json({ model: "gpt-test", output_text: "검색 결과 요약" }));
    const provider = new OpenAiProvider({ apiKey: "secret", model: "gpt-test", fetch: fetchMock });
    const request = { messages: [{ role: "user" as const, content: "검색해줘" }], systemPrompt: "be helpful" };
    const selected = await provider.selectTool(request, [
      { name: "web_search.search", description: "search", inputSchema: { type: "object" } },
    ]);
    expect(selected).not.toBeNull();

    await expect(provider.generateWithToolResult(request, selected!, { success: true, data: [{ title: "Result" }] }))
      .resolves.toEqual({ text: "검색 결과 요약", model: "gpt-test" });

    const secondBody = JSON.parse(String(fetchMock.mock.calls[1]?.[1]?.body)) as {
      previous_response_id?:string;
      input: Array<{ type?: string; call_id?: string; name?: string }>;
    };
    expect(secondBody.previous_response_id).toBe("resp-1");
    expect(secondBody.input).toEqual(expect.arrayContaining([
      expect.objectContaining({ type: "function_call_output", call_id: "call-2" }),
    ]));
    expect(secondBody.input).toHaveLength(1);
  });
});
