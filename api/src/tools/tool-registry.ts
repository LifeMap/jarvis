import { CalendarSearchTool } from "./calendar/calendar-tool";
import { CalendarCreateTool, CalendarDeleteTool, CalendarUpdateTool } from "./calendar/calendar-write-tools";
import { GmailSearchTool } from "./gmail/gmail-tool";
import { GmailReplyTool, GmailSendTool } from "./gmail/gmail-write-tools";
import { WebSearchTool } from "./search/search-tool";
import type { ToolContext, ToolDefinition, ToolExecutionAuthorization } from "./types";
import { ToolPolicyError } from "./types";
import type { SchedulerService } from "../scheduler/scheduler-service";
import { SchedulerCreateTool } from "../scheduler/scheduler-tool";
import type { ToolProviderIdentity, ToolProviderSet } from "./provider-types";

export class ToolRegistry {
  readonly tools: ToolDefinition[];
  readonly #providersByTool = new Map<string, ToolProviderIdentity>();
  constructor(providers: ToolProviderSet, scheduler?: SchedulerService, additional: Array<{tool:ToolDefinition;identity:ToolProviderIdentity}> = []) {
    const gmailTools = [new GmailSearchTool(providers.gmail.client), new GmailSendTool(providers.gmail.client), new GmailReplyTool(providers.gmail.client)];
    const calendarTools = [new CalendarSearchTool(providers.calendar.client), new CalendarCreateTool(providers.calendar.client), new CalendarUpdateTool(providers.calendar.client), new CalendarDeleteTool(providers.calendar.client)];
    const searchTools = [new WebSearchTool(providers.search.provider)];
    const schedulerTools = scheduler ? [new SchedulerCreateTool(scheduler)] : [];
    this.tools = [...gmailTools, ...calendarTools, ...searchTools, ...schedulerTools,...additional.map(item=>item.tool)];
    for (const tool of gmailTools) this.#providersByTool.set(tool.name, providers.gmail.identity);
    for (const tool of calendarTools) this.#providersByTool.set(tool.name, providers.calendar.identity);
    for (const tool of searchTools) this.#providersByTool.set(tool.name, providers.search.identity);
    for (const tool of schedulerTools) this.#providersByTool.set(tool.name, { service: "scheduler", implementation: "cloudflare-agents" });
    for(const item of additional)this.#providersByTool.set(item.tool.name,item.identity);
  }
  definitions() { return this.tools.map((tool) => ({ name: tool.name, description: tool.description, inputSchema: tool.inputSchema })); }
  get(name: string): ToolDefinition | undefined { return this.tools.find((tool) => tool.name === name); }
  provider(name: string): ToolProviderIdentity | undefined { return this.#providersByTool.get(name); }
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
