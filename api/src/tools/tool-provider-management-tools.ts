import type { ToolContext, ToolDefinition } from "./types";
import { ToolError } from "./types";
import type { ToolProviderConfigurationService, ToolProviderState } from "./tool-provider-configuration-service";
import type { DynamicToolProviderId, DynamicToolService, RegisteredToolProvider, ToolProviderSelection } from "./tool-provider-registry";

type StoredSelection = ToolProviderSelection & { updatedAt: string };

export type ToolProviderManagementIntent = { toolName: string; arguments: Record<string, unknown> };

export function createToolProviderManagementTools(service: ToolProviderConfigurationService): ToolDefinition[] {
  return [
    new GetActiveToolProviderTool(service), new GetDefaultToolProviderTool(service),
    new ListToolProvidersTool(service), new ListActiveToolProvidersTool(service),
    new SetActiveToolProviderTool(service), new ResetToolProviderTool(service),
  ];
}

export function parseToolProviderManagementIntent(message: string): ToolProviderManagementIntent | null {
  const text = message.trim();
  const management = /(provider|프로바이더|연결\s*방식|외부\s*서비스.*상태)/i.test(text)
    || (/mcp/i.test(text) && /(바꿔|변경|설정|전환|사용해|switch|change|set)/i.test(text));
  if (!management) return null;
  if (/(전부|전체|모두|all).*(상태|provider|프로바이더)|(외부\s*서비스).*(상태|보여|알려)/i.test(text)) {
    return { toolName: "tool_provider.list_active", arguments: {} };
  }
  const service = parseService(text);
  if (!service) {
    return { toolName: "tool_provider.get_active", arguments: { service: "unknown" } };
  }
  if (/(기본|default).*(돌아|되돌|복귀|reset)|(돌아|되돌|복귀|reset).*(기본|default)/i.test(text)) {
    return { toolName: "tool_provider.reset", arguments: { service } };
  }
  if (/(사용\s*가능|목록|리스트|list|available)/i.test(text)) {
    return { toolName: "tool_provider.list", arguments: { service } };
  }
  if (/(바꿔|변경|설정|전환|사용해|switch|change|set)/i.test(text)) {
    return { toolName: "tool_provider.set_active", arguments: { service, provider: parseProviderId(text, service) } };
  }
  if (/(기본|default)/i.test(text)) return { toolName: "tool_provider.get_default", arguments: { service } };
  return { toolName: "tool_provider.get_active", arguments: { service } };
}

class GetActiveToolProviderTool implements ToolDefinition {
  name = "tool_provider.get_active"; description = "Get the active Provider for one external Tool service.";
  inputSchema = serviceSchema(); policy = "AUTO" as const; requiresApproval = false;
  constructor(private readonly service: ToolProviderConfigurationService) {}
  async execute(input: Record<string, unknown>, _context: ToolContext) { return this.service.getActive(requireService(input.service)); }
  summarize(result: ToolProviderState) { return `${serviceName(result.service)}\nActive: ${result.providerId}\nDefault 여부: ${result.isDefault ? "Yes" : "No"}\nStatus: ${result.enabled ? "available" : `unavailable (${result.unavailableReason ?? "설정 필요"})`}`; }
}
class GetDefaultToolProviderTool implements ToolDefinition {
  name = "tool_provider.get_default"; description = "Get the default Provider for one external Tool service.";
  inputSchema = serviceSchema(); policy = "AUTO" as const; requiresApproval = false;
  constructor(private readonly service: ToolProviderConfigurationService) {}
  async execute(input: Record<string, unknown>, _context: ToolContext) { return this.service.getDefault(requireService(input.service)); }
  summarize(result: ToolProviderState) { return `${serviceName(result.service)} 기본 Provider: ${result.providerId}\nStatus: ${result.enabled ? "available" : `unavailable (${result.unavailableReason ?? "설정 필요"})`}`; }
}
class ListToolProvidersTool implements ToolDefinition {
  name = "tool_provider.list"; description = "List registered Providers for one external Tool service.";
  inputSchema = serviceSchema(); policy = "AUTO" as const; requiresApproval = false;
  constructor(private readonly service: ToolProviderConfigurationService) {}
  async execute(input: Record<string, unknown>, _context: ToolContext) { return this.service.list(requireService(input.service)); }
  summarize(result: RegisteredToolProvider[]) { return result.map((item) => `- ${item.providerId}: ${item.enabled ? "available" : `unavailable (${item.unavailableReason ?? "설정 필요"})`}`).join("\n"); }
}
class ListActiveToolProvidersTool implements ToolDefinition {
  name = "tool_provider.list_active"; description = "List active Provider states for all external Tool services.";
  inputSchema = { type: "object", properties: {} }; policy = "AUTO" as const; requiresApproval = false;
  constructor(private readonly service: ToolProviderConfigurationService) {}
  async execute(_input: Record<string, unknown>, _context: ToolContext) { return this.service.listActive(); }
  summarize(result: ToolProviderState[]) {
    return result.map((item) => `${serviceName(item.service)}\nActive: ${item.providerId}\nDefault: ${this.service.getDefault(item.service).providerId}\nStatus: ${item.enabled ? "available" : "unavailable"}`).join("\n\n");
  }
}
class SetActiveToolProviderTool implements ToolDefinition {
  name = "tool_provider.set_active"; description = "Set an explicitly requested registered Provider for one external Tool service.";
  inputSchema = { type: "object", properties: { service: { type: "string" }, provider: { type: "string" } }, required: ["service", "provider"] };
  policy = "AUTO" as const; requiresApproval = false;
  constructor(private readonly service: ToolProviderConfigurationService) {}
  async execute(input: Record<string, unknown>, _context: ToolContext) {
    const service = requireService(input.service);
    if (typeof input.provider !== "string" || !input.provider) throw new ToolError("Invalid Tool Provider", "Provider ID가 올바르지 않습니다. 기존 설정은 유지됩니다.");
    return this.service.setActive(service, input.provider as DynamicToolProviderId);
  }
  summarize(result: StoredSelection) { return `${serviceName(result.service)} Provider를 ${result.providerId}(으)로 변경했습니다. 다음 Tool 실행부터 적용됩니다.`; }
}
class ResetToolProviderTool implements ToolDefinition {
  name = "tool_provider.reset"; description = "Reset one external Tool service to its configured default Provider.";
  inputSchema = serviceSchema(); policy = "AUTO" as const; requiresApproval = false;
  constructor(private readonly service: ToolProviderConfigurationService) {}
  async execute(input: Record<string, unknown>, _context: ToolContext) { return this.service.reset(requireService(input.service)); }
  summarize(result: StoredSelection) { return `${serviceName(result.service)} Provider를 기본값 ${result.providerId}(으)로 되돌렸습니다.`; }
}

function serviceSchema() { return { type: "object", properties: { service: { type: "string", enum: ["gmail", "calendar", "search"] } }, required: ["service"] }; }
function requireService(value: unknown): DynamicToolService {
  if (value === "gmail" || value === "calendar" || value === "search") return value;
  throw new ToolError("Unknown Tool service", "지원하지 않는 외부 Tool 서비스입니다. 기존 설정은 유지됩니다.");
}
function parseService(text: string): DynamicToolService | null {
  if (/gmail|지메일|메일/i.test(text)) return "gmail";
  if (/calendar|캘린더|일정/i.test(text)) return "calendar";
  if (/search|검색/i.test(text)) return "search";
  return null;
}
function parseProviderId(text: string, service: DynamicToolService): string {
  const known = ["gmail-api", "google-calendar-api", "brave-api", "serpapi"].find((id) => text.toLowerCase().includes(id));
  if (known) return known;
  const configured=text.match(/(?:provider|프로바이더)(?:를|로|으로)?\s+([a-z0-9][a-z0-9_-]{1,63})/i)?.[1];
  if(configured)return configured.toLowerCase();
  if (/mcp/i.test(text)) return `${service}-mcp`;
  return service === "gmail" ? "gmail-api" : service === "calendar" ? "google-calendar-api" : /serp/i.test(text) ? "serpapi" : "brave-api";
}
function serviceName(service: DynamicToolService): string { return service === "gmail" ? "Gmail" : service === "calendar" ? "Calendar" : "Search"; }
