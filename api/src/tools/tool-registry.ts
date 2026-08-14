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
import type { FallbackConfigurationService } from "../runtime/fallback-configuration";
import { classifyProviderFailure } from "../runtime/provider-health";
import type { ProviderHealthService } from "../runtime/provider-health-service";

export interface ToolFallbackRuntime {
  providers: ToolProviderSet;
  services: ReadonlySet<"gmail" | "calendar" | "search">;
  configuration: FallbackConfigurationService;
  health: ProviderHealthService;
}

export class ToolRegistry {
  readonly tools: ToolDefinition[];
  readonly #providersByTool = new Map<string, ToolProviderIdentity>();
  readonly #fallbackTools = new Map<string, ToolDefinition>();
  readonly #fallbackProvidersByTool = new Map<string, ToolProviderIdentity>();
  constructor(providers: ToolProviderSet, scheduler?: SchedulerService, additional: Array<{tool:ToolDefinition;identity:ToolProviderIdentity}> = [], private readonly fallback?: ToolFallbackRuntime) {
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
    if (fallback) {
      const fallbackGmail = [new GmailSearchTool(fallback.providers.gmail.client)];
      const fallbackCalendar = [new CalendarSearchTool(fallback.providers.calendar.client)];
      const fallbackSearch = [new WebSearchTool(fallback.providers.search.provider)];
      if (fallback.services.has("gmail")) for (const tool of fallbackGmail) { this.#fallbackTools.set(tool.name, tool); this.#fallbackProvidersByTool.set(tool.name, fallback.providers.gmail.identity); }
      if (fallback.services.has("calendar")) for (const tool of fallbackCalendar) { this.#fallbackTools.set(tool.name, tool); this.#fallbackProvidersByTool.set(tool.name, fallback.providers.calendar.identity); }
      if (fallback.services.has("search")) for (const tool of fallbackSearch) { this.#fallbackTools.set(tool.name, tool); this.#fallbackProvidersByTool.set(tool.name, fallback.providers.search.identity); }
    }
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
    const primary = this.provider(name);
    const capability=requiredCapability(name);
    if(primary?.capabilities&&capability&&!primary.capabilities.includes(capability))throw new ToolPolicyError("POLICY_MISMATCH",`현재 ${primary.implementation} 인증에는 ${capability} 권한이 없습니다. 계정을 필요한 scope로 다시 연결해 주세요.`);
    const started = Date.now();
    try {
      const result = await tool.execute(input, context);
      if (primary && this.fallback) this.fallback.health.markSuccess(toolTarget(primary), Date.now() - started);
      return { tool, result, fallbackUsed: false };
    } catch (error) {
      const failure = classifyProviderFailure(error);
      if (primary && this.fallback && failure.fallbackEligible) this.fallback.health.markFailure(toolTarget(primary), failure.type, Date.now() - started);
      const fallbackTool = this.#fallbackTools.get(name);
      const fallbackProvider = this.#fallbackProvidersByTool.get(name);
      // Mutation tools are never replayed: a timeout may mean the first provider already committed the change.
      if (!this.fallback || !primary || !fallbackTool || !fallbackProvider || tool.policy !== "AUTO" || !failure.fallbackEligible) {
        if (this.fallback && primary && fallbackProvider && tool.policy !== "AUTO") this.fallback.configuration.event(`tools.${primary.service}` as "tools.gmail" | "tools.calendar" | "tools.search", primary.implementation, fallbackProvider.implementation, failure, "blocked");
        throw error;
      }
      try {
        const fallbackStarted = Date.now();
        const result = await fallbackTool.execute(input, context);
        this.fallback.health.markSuccess(toolTarget(fallbackProvider), Date.now() - fallbackStarted);
        this.fallback.configuration.event(`tools.${primary.service}` as "tools.gmail" | "tools.calendar" | "tools.search", primary.implementation, fallbackProvider.implementation, failure, "success");
        return { tool, result, fallbackUsed: true, primaryProvider: primary.implementation, fallbackProvider: fallbackProvider.implementation, failureType: failure.type };
      } catch (fallbackError) {
        this.fallback.configuration.event(`tools.${primary.service}` as "tools.gmail" | "tools.calendar" | "tools.search", primary.implementation, fallbackProvider.implementation, failure, "failed");
        throw fallbackError;
      }
    }
  }
}

function toolTarget(identity: ToolProviderIdentity) { return `tools.${identity.service}.${identity.implementation}`; }
function requiredCapability(name:string){if(name==="gmail.search_messages")return"read";if(name==="gmail.send")return"send";if(name==="gmail.reply")return"reply";if(name==="google_calendar.search_events")return"read";if(name==="calendar.create")return"create";if(name==="calendar.update")return"update";if(name==="calendar.delete")return"delete";return undefined;}
