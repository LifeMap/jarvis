import type { ToolContext, ToolDefinition } from "../tools/types";
import { ToolError } from "../tools/types";
import type { ModelConfigurationService } from "./model-configuration-service";
import type { ModelProviderId } from "./types";

export type ModelManagementIntent = { toolName: string; arguments: Record<string, unknown> };

export function createModelManagementTools(service: ModelConfigurationService): ToolDefinition[] {
  return [new GetActiveModelTool(service), new ListAvailableModelsTool(service), new SetActiveModelTool(service)];
}

export function parseModelManagementIntent(message: string, service: ModelConfigurationService): ModelManagementIntent | null {
  const text = message.trim();
  if (/(사용\s*가능|사용할\s*수\s*있는|available).*(모델|model)|(모델|model).*(목록|리스트|list)/i.test(text)) {
    return { toolName: "model.list_available", arguments: {} };
  }
  const change = /(바꿔|변경|전환|사용해|switch|change|set)/i.test(text);
  if (change && /(모델|model|workers\s*-?\s*ai|open\s*-?\s*ai|오픈에이아이|워커스)/i.test(text)) {
    const provider = parseProvider(text);
    if (!provider) return { toolName: "model.set_active", arguments: { provider: "unknown" } };
    const knownModel = service.registry.list().find((entry) => text.includes(entry.model))?.model;
    const explicitModel = text.match(/(?:의|에서)\s*([@A-Za-z0-9._:/-]+)\s*모델/i)?.[1];
    return { toolName: "model.set_active", arguments: { provider, ...(knownModel ?? explicitModel ? { model: knownModel ?? explicitModel } : {}) } };
  }
  if (/(현재|지금|current|which|무슨|어떤).*(모델|model)|(모델|model).*(뭐|무엇|알려|확인)/i.test(text)) {
    return { toolName: "model.get_active", arguments: {} };
  }
  return null;
}

class GetActiveModelTool implements ToolDefinition<ReturnType<ModelConfigurationService["getActive"]>> {
  name = "model.get_active"; description = "Get the active Model Provider and model.";
  inputSchema = { type: "object", properties: {} }; policy = "AUTO" as const; requiresApproval = false;
  constructor(private readonly service: ModelConfigurationService) {}
  async execute(_input: Record<string, unknown>, _context: ToolContext) { return this.service.getActive(); }
  summarize(result: ReturnType<ModelConfigurationService["getActive"]>) {
    return `현재 모델은 ${providerName(result.provider)}의 ${result.model}입니다.${result.enabled ? "" : " 현재 Provider 설정을 사용할 수 없습니다."}`;
  }
}

class ListAvailableModelsTool implements ToolDefinition<ReturnType<ModelConfigurationService["listAvailable"]>> {
  name = "model.list_available"; description = "List explicitly registered Jarvis models and availability.";
  inputSchema = { type: "object", properties: {} }; policy = "AUTO" as const; requiresApproval = false;
  constructor(private readonly service: ModelConfigurationService) {}
  async execute(_input: Record<string, unknown>, _context: ToolContext) { return this.service.listAvailable(); }
  summarize(result: ReturnType<ModelConfigurationService["listAvailable"]>) {
    const lines = result.map((model) => `- ${providerName(model.provider)} / ${model.model}: ${model.enabled ? "사용 가능" : `사용 불가 (${model.unavailableReason ?? "설정 필요"})`}`);
    return `등록된 모델입니다.\n${lines.join("\n")}`;
  }
}

class SetActiveModelTool implements ToolDefinition<ReturnType<ModelConfigurationService["setActive"]>> {
  name = "model.set_active"; description = "Set the active model only after an explicit user request.";
  inputSchema = { type: "object", properties: { provider: { type: "string", enum: ["workers-ai", "openai"] }, model: { type: "string" } }, required: ["provider"] };
  policy = "AUTO" as const; requiresApproval = false;
  constructor(private readonly service: ModelConfigurationService) {}
  async execute(input: Record<string, unknown>, _context: ToolContext) {
    if (!isProvider(input.provider)) throw new ToolError("Invalid Model Provider", "지원하지 않는 Model Provider입니다. 기존 모델 설정은 유지됩니다.");
    if (input.model !== undefined && typeof input.model !== "string") throw new ToolError("Invalid model", "모델 ID가 올바르지 않습니다. 기존 모델 설정은 유지됩니다.");
    try { return this.service.setActive(input.provider, input.model); }
    catch (error) { throw new ToolError("Model change rejected", `${error instanceof Error ? error.message : "모델을 변경할 수 없습니다."} 기존 모델 설정은 유지됩니다.`, { cause: error }); }
  }
  summarize(result: ReturnType<ModelConfigurationService["setActive"]>) { return `활성 모델을 ${providerName(result.provider)}의 ${result.model}(으)로 변경했습니다. 다음 요청부터 적용됩니다.`; }
}

function parseProvider(text: string): ModelProviderId | null {
  if (/workers\s*-?\s*ai|워커스\s*AI|워커스|Cloudflare\s*(Workers\s*)?AI/i.test(text)) return "workers-ai";
  if (/open\s*-?\s*ai|오픈에이아이/i.test(text)) return "openai";
  return null;
}
function isProvider(value: unknown): value is ModelProviderId { return value === "workers-ai" || value === "openai"; }
function providerName(provider: ModelProviderId): string { return provider === "workers-ai" ? "Workers AI" : provider === "openai" ? "OpenAI" : "Test Provider"; }
