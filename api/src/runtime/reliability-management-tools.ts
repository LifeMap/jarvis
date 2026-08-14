import type { ModelProviderId } from "../llm/types";
import type { DynamicToolService } from "../tools/tool-provider-registry";
import type { ToolDefinition } from "../tools/types";
import { ToolError } from "../tools/types";
import type { FallbackConfigurationService, FallbackTarget } from "./fallback-configuration";
import type { ProviderHealthService } from "./provider-health-service";

export interface ReliabilityIntent { toolName: string; arguments: Record<string, unknown> }

export function createReliabilityManagementTools(fallbacks: FallbackConfigurationService, health: ProviderHealthService): ToolDefinition[] {
  return [
    tool("provider_health.check", "Provider 상태를 확인합니다.", async input => health.check(text(input.target)), result => summarizeHealth(result as ReturnType<ProviderHealthService["check"]>)),
    tool("fallback.list", "Fallback 설정을 조회합니다.", async () => fallbacks.list(), result => summarizeFallbacks(result as ReturnType<FallbackConfigurationService["list"]>)),
    tool("fallback.events", "최근 fallback 실행 내역을 조회합니다.", async input => fallbacks.events(number(input.limit) ?? 20), result => summarizeEvents(result as ReturnType<FallbackConfigurationService["events"]>)),
    tool("fallback.set", "Fallback을 설정합니다.", async input => {
      const target = fallbackTarget(input.target);
      const provider = required(input.provider, "provider");
      if (target === "model") return fallbacks.setModel(provider as ModelProviderId, text(input.model));
      return fallbacks.setTool(target.slice(6) as DynamicToolService, provider);
    }, result => `Fallback을 설정했습니다: ${JSON.stringify(result)}`),
    tool("fallback.remove", "Fallback 설정을 제거합니다.", async input => fallbacks.remove(fallbackTarget(input.target)), result => result ? `Fallback 설정을 제거했습니다: ${JSON.stringify(result)}` : "설정된 fallback이 없습니다."),
  ];
}

export function parseReliabilityManagementIntent(message: string): ReliabilityIntent | null {
  const normalized = message.trim();
  const health = /(상태|health|정상|연결).*(모델|provider|공급자|mcp)|^(모델|provider|공급자|mcp).*(상태|health|정상)/i.test(normalized);
  if (health && /(확인|알려|보여|점검|check)/i.test(normalized)) return { toolName: "provider_health.check", arguments: { target: targetHint(normalized) } };
  if (/(fallback|대체).*(내역|기록|실행)/i.test(normalized) && /(보여|알려|조회)/i.test(normalized)) return { toolName: "fallback.events", arguments: {} };
  if (/(fallback|대체).*(목록|설정|상태)/i.test(normalized) && /(보여|알려|조회)/i.test(normalized)) return { toolName: "fallback.list", arguments: {} };
  const mutation = /(사용해|써|설정해|지정해|바꿔|변경해|제거해|삭제해|해제해)/i.test(normalized);
  if (!mutation || !/(fallback|대체|실패하면|안 되면)/i.test(normalized)) return null;
  const target = targetHint(normalized);
  if (!target) return null;
  if (/(제거|삭제|해제)/i.test(normalized)) return { toolName: "fallback.remove", arguments: { target } };
  const provider = providerHint(normalized, target);
  if (!provider) return null;
  return { toolName: "fallback.set", arguments: { target, provider, ...(target === "model" && provider === "workers-ai" ? { model: "@cf/qwen/qwen3-30b-a3b-fp8" } : {}) } };
}

function tool(name: string, description: string, execute: ToolDefinition["execute"], summarize: ToolDefinition["summarize"]): ToolDefinition { return { name, description, inputSchema: { type: "object" }, policy: "AUTO", requiresApproval: false, execute, summarize }; }
function targetHint(message: string): FallbackTarget | undefined { if (/gmail|메일/i.test(message)) return "tools.gmail"; if (/calendar|캘린더|일정/i.test(message)) return "tools.calendar"; if (/search|검색/i.test(message)) return "tools.search"; if (/model|모델|openai|workers ai|qwen/i.test(message)) return "model"; return undefined; }
function providerHint(message: string, target: FallbackTarget): string | undefined { const candidate=message.split(/실패하면|안\s*되면/i).at(-1)??message;if (/workers ai|qwen/i.test(candidate)) return "workers-ai"; if (/openai/i.test(candidate)) return "openai"; if (/gmail-api|api/i.test(candidate) && target === "tools.gmail") return "gmail-api"; if (/google-calendar-api|api/i.test(candidate) && target === "tools.calendar") return "google-calendar-api"; if (/brave-api|brave|api/i.test(candidate) && target === "tools.search") return "brave-api"; const explicit = candidate.match(/(?:provider|공급자)\s*(?:를|는|:)?\s*([a-z0-9@/._-]+)/i)?.[1]; return explicit; }
function fallbackTarget(value: unknown): FallbackTarget { const target = required(value, "target"); if (target === "model" || target === "tools.gmail" || target === "tools.calendar" || target === "tools.search") return target; throw new ToolError("Invalid fallback target", "지원하지 않는 fallback 대상입니다."); }
function required(value: unknown, field: string) { if (typeof value !== "string" || !value.trim()) throw new ToolError(`Missing ${field}`, `${field} 값이 필요합니다.`); return value.trim(); }
function text(value: unknown) { return typeof value === "string" && value.trim() ? value.trim() : undefined; }
function number(value: unknown) { return typeof value === "number" && Number.isFinite(value) ? value : undefined; }
function summarizeHealth(items: ReturnType<ProviderHealthService["check"]>) { return items.length ? `Provider 상태\n${items.map(item => `- ${item.target}: ${item.status}${item.latencyMs !== undefined ? ` (${item.latencyMs}ms)` : ""}${item.reason ? ` — ${item.reason}` : ""}`).join("\n")}` : "확인할 Provider가 없습니다."; }
function summarizeFallbacks(items: ReturnType<FallbackConfigurationService["list"]>) { return items.length ? `Fallback 설정\n${items.map(item => `- ${item.target}: ${item.providerId}${item.model ? `/${item.model}` : ""}`).join("\n")}` : "설정된 fallback이 없습니다. 장애 시 자동으로 다른 Provider를 사용하지 않습니다."; }
function summarizeEvents(items: ReturnType<FallbackConfigurationService["events"]>) { return items.length ? `최근 fallback 실행 내역\n${items.map(item => `- ${item.timestamp} ${item.target}: ${item.primaryProvider} → ${item.fallbackProvider} (${item.failureType}, ${item.fallbackResult})`).join("\n")}` : "fallback 실행 내역이 없습니다."; }
