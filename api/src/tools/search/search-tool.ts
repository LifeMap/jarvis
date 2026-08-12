import type { ToolContext, ToolDefinition } from "../types";
import { ToolError } from "../types";
import type { SearchProvider, SearchResult } from "./search-provider";

export interface WebSearchInput { query: string; count?: number }
export class WebSearchTool implements ToolDefinition<SearchResult[]> {
  name = "web_search.search";
  description = "Search the current public web for recent or changing information.";
  policy = "AUTO" as const;
  requiresApproval = false as const;
  inputSchema = { type: "object", properties: { query: { type: "string" }, count: { type: "integer", minimum: 1, maximum: 10 } }, required: ["query"] };
  constructor(private readonly provider: SearchProvider) {}
  async execute(rawInput: Record<string, unknown>, _context: ToolContext): Promise<SearchResult[]> {
    const input = rawInput as unknown as WebSearchInput;
    if (!input.query?.trim()) throw new ToolError("Empty query", "검색어가 비어 있습니다.");
    try { return await this.provider.search(input.query.trim(), input.count ?? 5); }
    catch (error) { throw new ToolError("Web search failed", "웹 검색 서비스에 연결할 수 없습니다.", { cause: error }); }
  }
  summarize(result: SearchResult[]): string { const providers=[...new Set(result.map(item=>item.provider).filter(Boolean))];return `Web search results: ${result.length}${providers.length?` via ${providers.join(", ")}`:""}`; }
}
