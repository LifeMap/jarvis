import type { Env } from "../env";
import type { GoogleOAuthService } from "../oauth/google-oauth-service";
import { GoogleCalendarClient } from "./calendar/calendar-client";
import { CalendarSearchTool } from "./calendar/calendar-tool";
import { CalendarCreateTool, CalendarDeleteTool, CalendarUpdateTool } from "./calendar/calendar-write-tools";
import { GoogleGmailClient } from "./gmail/gmail-client";
import { GmailSearchTool } from "./gmail/gmail-tool";
import { GmailReplyTool, GmailSendTool } from "./gmail/gmail-write-tools";
import { BraveSearchProvider, UnavailableSearchProvider } from "./search/search-provider";
import { WebSearchTool } from "./search/search-tool";
import type { ToolContext, ToolDefinition, ToolExecutionAuthorization } from "./types";
import { ToolPolicyError } from "./types";

export class ToolRegistry {
  readonly tools: ToolDefinition[];
  constructor(env: Env, oauth: GoogleOAuthService) {
    const accessToken = () => oauth.getAccessToken();
    const searchProvider = env.SEARCH_PROVIDER === "brave" && env.SEARCH_API_KEY
      ? new BraveSearchProvider(env.SEARCH_API_KEY)
      : new UnavailableSearchProvider("SEARCH_PROVIDER 또는 SEARCH_API_KEY가 설정되지 않았습니다.");
    const gmail = new GoogleGmailClient(accessToken);
    const calendar = new GoogleCalendarClient(accessToken);
    this.tools = [
      new GmailSearchTool(gmail), new GmailSendTool(gmail), new GmailReplyTool(gmail),
      new CalendarSearchTool(calendar), new CalendarCreateTool(calendar), new CalendarUpdateTool(calendar), new CalendarDeleteTool(calendar),
      new WebSearchTool(searchProvider),
    ];
  }
  definitions() { return this.tools.map((tool) => ({ name: tool.name, description: tool.description, inputSchema: tool.inputSchema })); }
  get(name: string): ToolDefinition | undefined { return this.tools.find((tool) => tool.name === name); }
  async execute(name: string, input: Record<string, unknown>, context: ToolContext, authorization?: ToolExecutionAuthorization) {
    const tool = this.get(name);
    if (!tool) throw new ToolPolicyError("POLICY_MISMATCH", "Tool not found");
    if (tool.policy === "APPROVAL_REQUIRED" && (!authorization || authorization.toolName !== name)) {
      throw new ToolPolicyError("APPROVAL_REQUIRED", "승인되지 않은 상태 변경 Tool 실행이 차단되었습니다.");
    }
    if (tool.policy === "AUTO" && authorization) throw new ToolPolicyError("POLICY_MISMATCH", "Read-only Tool에는 승인 권한을 사용할 수 없습니다.");
    return { tool, result: await tool.execute(input, context) };
  }
}
