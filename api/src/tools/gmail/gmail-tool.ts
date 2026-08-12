import type { ToolContext, ToolDefinition } from "../types";
import { ToolError } from "../types";
import { GmailApiError, type GmailMessage, type GmailSearchClient } from "./gmail-client";

export interface GmailSearchInput { query?: string; from?: string; keyword?: string; maxResults?: number }

export class GmailSearchTool implements ToolDefinition<GmailMessage[]> {
  name = "gmail.search_messages";
  description = "Search or list recent Gmail messages. Read-only.";
  policy = "AUTO" as const;
  requiresApproval = false as const;
  inputSchema = {
    type: "object",
    properties: {
      query: { type: "string", description: "Gmail search query such as newer_than:1d" },
      from: { type: "string", description: "Sender name or email" },
      keyword: { type: "string", description: "Keyword to search" },
      maxResults: { type: "integer", minimum: 1, maximum: 20 },
    },
  };
  constructor(private readonly client: GmailSearchClient) {}
  async execute(rawInput: Record<string, unknown>, _context: ToolContext): Promise<GmailMessage[]> {
    const input = rawInput as GmailSearchInput;
    const query = [input.query, input.from ? `from:(${input.from})` : "", input.keyword].filter(Boolean).join(" ");
    try { return await this.client.search({ ...(query ? { query } : {}), maxResults: input.maxResults ?? 5 }); }
    catch (error) { throw new ToolError("Gmail search failed", gmailUserMessage(error), { cause: error }); }
  }
  summarize(result: GmailMessage[]): string { return `Gmail messages: ${result.length}`; }
}
function gmailUserMessage(error:unknown):string{
  if(error instanceof GmailApiError){
    if(error.status===401)return "Gmail 인증이 만료되었습니다. Google 계정을 다시 연결해 주세요.";
    if(error.status===403)return "Gmail API 접근이 거부되었습니다. Google Cloud 프로젝트에서 Gmail API 활성화와 OAuth 권한을 확인해 주세요.";
    if(error.status===429)return "Gmail API 사용량 제한에 도달했습니다. 잠시 후 다시 시도해 주세요.";
    return `Gmail API 요청이 실패했습니다 (HTTP ${error.status}).`;
  }
  return "Gmail을 조회할 수 없습니다. Google 연결 상태를 확인해 주세요.";
}
