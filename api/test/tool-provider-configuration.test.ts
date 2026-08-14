import { describe, expect, it, vi } from "vitest";
import type { Env } from "../src/env";
import { createToolProviders } from "../src/tools/provider-factory";
import { ToolProviderConfigurationRepository } from "../src/tools/tool-provider-configuration-repository";
import { ToolProviderConfigurationService } from "../src/tools/tool-provider-configuration-service";
import { createToolProviderManagementTools, parseToolProviderManagementIntent } from "../src/tools/tool-provider-management-tools";
import { createToolProviderRegistry } from "../src/tools/tool-provider-registry";
import { ToolProviderResolver } from "../src/tools/tool-provider-resolver";
import type { SqlExecutor } from "../src/storage/sql";

function fixture(env: Env, googleConnected = true) {
  const rows = new Map<string, { service: string; provider_id: string; updated_at: string }>();
  const sql: SqlExecutor["sql"] = ((strings: TemplateStringsArray, ...values: Array<string | number | boolean | null>) => {
    const statement = strings.join("?");
    if (statement.includes("SELECT service")) {
      const row = rows.get(String(values[0]));
      return row ? [row] : [];
    }
    if (statement.includes("INSERT INTO tool_provider_configuration")) {
      rows.set(String(values[0]), { service: String(values[0]), provider_id: String(values[1]), updated_at: String(values[2]) });
    }
    return [];
  }) as SqlExecutor["sql"];
  const service = new ToolProviderConfigurationService(
    new ToolProviderConfigurationRepository({ sql }), createToolProviderRegistry(env, { googleConnected }),
  );
  return { service, rows, sql };
}

const configuredEnv = {
  GOOGLE_CLIENT_ID: "client", GOOGLE_CLIENT_SECRET: "secret",
  SEARCH_API_KEY: "brave-key", SERP_API_KEY: "serp-key", SEARCH_FALLBACK_PROVIDER: "serpapi",
} as Env;

describe("Dynamic Tool Provider configuration", () => {
  it("bootstraps explicit service defaults without persisting an arbitrary choice", () => {
    const { service, rows } = fixture(configuredEnv);
    expect(service.listActive()).toMatchObject([
      { service: "gmail", providerId: "gmail-api", source: "default", isDefault: true, enabled: true },
      { service: "calendar", providerId: "google-calendar-api", source: "default", isDefault: true, enabled: true },
      { service: "search", providerId: "brave-api", source: "default", isDefault: true, enabled: true },
    ]);
    expect(rows.size).toBe(0);
  });

  it("persists a Search Provider change and Resolver applies it to the existing implementation", () => {
    const { service, rows, sql } = fixture(configuredEnv);
    service.setActive("search", "serpapi");
    const reconnected = new ToolProviderConfigurationService(
      new ToolProviderConfigurationRepository({ sql }), createToolProviderRegistry(configuredEnv, { googleConnected: true }),
    );
    expect(new ToolProviderResolver(reconnected).resolveAll()).toMatchObject({ search: "serpapi" });
    const providers = createToolProviders(configuredEnv, { getAccessToken: vi.fn().mockResolvedValue("token") }, new ToolProviderResolver(reconnected).resolveAll());
    expect(providers.search.identity).toMatchObject({ service: "search", implementation: "serpapi" });
    expect(rows.get("search")).toMatchObject({ provider_id: "serpapi" });
  });

  it("resets a persisted Provider to the immutable service default", () => {
    const { service } = fixture(configuredEnv);
    service.setActive("search", "serpapi");
    service.reset("search");
    expect(service.getActive("search")).toMatchObject({ providerId: "brave-api", isDefault: true, source: "persistent" });
  });

  it("rejects unregistered, cross-service, and disabled Providers without changing active state", () => {
    const { service, rows } = fixture({ SERP_API_KEY: "serp-key" } as Env, false);
    expect(() => service.setActive("gmail", "gmail-api")).toThrow("GOOGLE_CLIENT_ID");
    expect(() => service.setActive("search", "gmail-api")).toThrow("등록되어 있지 않습니다");
    expect(() => service.setActive("search", "brave-api")).toThrow("SEARCH_API_KEY");
    expect(() => service.setActive("gmail", "gmail-mcp" as never)).toThrow("등록되어 있지 않습니다");
    expect(rows.size).toBe(0);
    expect(service.getActive("search")).toMatchObject({ providerId: "brave-api", source: "default" });
  });

  it("maps explicit natural-language management commands only", async () => {
    const { service } = fixture(configuredEnv);
    expect(parseToolProviderManagementIntent("현재 외부 서비스 Provider 상태를 전부 보여줘.")).toEqual({ toolName: "tool_provider.list_active", arguments: {} });
    expect(parseToolProviderManagementIntent("Gmail Provider를 gmail-api로 설정해.")).toEqual({ toolName: "tool_provider.set_active", arguments: { service: "gmail", provider: "gmail-api" } });
    expect(parseToolProviderManagementIntent("Search를 기본 Provider로 되돌려.")).toEqual({ toolName: "tool_provider.reset", arguments: { service: "search" } });
    expect(parseToolProviderManagementIntent("Gmail을 MCP로 바꿔.")).toEqual({ toolName: "tool_provider.set_active", arguments: { service: "gmail", provider: "gmail-mcp" } });
    expect(parseToolProviderManagementIntent("최근 메일 알려줘.")).toBeNull();

    const intent = parseToolProviderManagementIntent("Search Provider를 serpapi로 변경해.")!;
    const tool = createToolProviderManagementTools(service).find((candidate) => candidate.name === intent.toolName)!;
    await tool.execute(intent.arguments, { timezone: "Asia/Seoul" });
    expect(service.getActive("search")).toMatchObject({ providerId: "serpapi", source: "persistent" });
    const activeTool = createToolProviderManagementTools(service).find((candidate) => candidate.name === "tool_provider.get_active")!;
    await expect(activeTool.execute({ service: "unknown" }, { timezone: "UTC" })).rejects.toThrow("Unknown Tool service");
  });
});
