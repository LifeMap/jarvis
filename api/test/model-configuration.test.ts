import { describe, expect, it, vi } from "vitest";
import type { Env } from "../src/env";
import { ModelConfigurationRepository } from "../src/llm/model-configuration-repository";
import { ModelConfigurationService } from "../src/llm/model-configuration-service";
import { createModelRegistry, DEFAULT_WORKERS_AI_MODEL } from "../src/llm/model-registry";
import { createModelProvider } from "../src/llm/provider-factory";
import { createModelManagementTools, parseModelManagementIntent } from "../src/llm/model-management-tools";
import type { SqlExecutor } from "../src/storage/sql";

function fixture(env: Env) {
  let row: { provider: string; model_id: string; updated_at: string } | null = null;
  const sql: SqlExecutor["sql"] = ((strings: TemplateStringsArray, ...values: Array<string | number | boolean | null>) => {
    const statement = strings.join("?");
    if (statement.includes("SELECT provider")) return row ? [row] : [];
    if (statement.includes("INSERT INTO model_configuration")) {
      row = { provider: String(values[0]), model_id: String(values[1]), updated_at: String(values[2]) };
    }
    return [];
  }) as SqlExecutor["sql"];
  const service = new ModelConfigurationService(new ModelConfigurationRepository({ sql }), createModelRegistry(env));
  return { service, getRow: () => row };
}

describe("Active Model configuration", () => {
  it("bootstraps the explicit Qwen default when persistent configuration is absent", () => {
    const env = {
      LLM_PROVIDER: "workers-ai", LLM_MODEL: DEFAULT_WORKERS_AI_MODEL,
      WORKERS_AI_MODEL: DEFAULT_WORKERS_AI_MODEL, AI: { run: vi.fn() },
    } as unknown as Env;
    const { service, getRow } = fixture(env);

    expect(service.getDefault()).toMatchObject({
      provider: "workers-ai", model: DEFAULT_WORKERS_AI_MODEL, enabled: true, isDefault: true,
    });
    expect(service.getActive()).toMatchObject({
      provider: "workers-ai", model: DEFAULT_WORKERS_AI_MODEL, source: "default", isDefault: true,
    });
    expect(getRow()).toBeNull();
  });

  it("reports a configuration error instead of selecting another model when the default is unavailable", () => {
    const env = {
      LLM_PROVIDER: "openai", LLM_MODEL: "gpt-test", OPENAI_API_KEY: "secret",
      WORKERS_AI_MODEL: DEFAULT_WORKERS_AI_MODEL,
    } as Env;
    const { service } = fixture(env);

    expect(service.getActive()).toMatchObject({ provider: "workers-ai", model: DEFAULT_WORKERS_AI_MODEL, enabled: false });
    expect(service.getActive().unavailableReason).toContain("Workers AI binding");
  });

  it("persists a valid change and creates that Provider for the next request", async () => {
    const run = vi.fn().mockResolvedValue({ response: "switched" });
    const env = {
      LLM_PROVIDER: "openai", LLM_MODEL: "gpt-test", OPENAI_API_KEY: "secret",
      WORKERS_AI_MODEL: "@cf/test/model", AI: { run },
    } as unknown as Env;
    const { service } = fixture(env);
    service.setActive("workers-ai", "@cf/test/model");
    const active = service.getActive();
    expect(active).toMatchObject({ provider: "workers-ai", model: "@cf/test/model", enabled: true });
    const provider = createModelProvider(env, active);
    await expect(provider.generate({ systemPrompt: "help", messages: [{ role: "user", content: "next" }] }))
      .resolves.toEqual({ text: "switched", model: "@cf/test/model" });
  });

  it("maps an explicit natural-language change to the management Tool", async () => {
    const env = {
      LLM_PROVIDER: "openai", LLM_MODEL: "gpt-test", OPENAI_API_KEY: "secret",
      WORKERS_AI_MODEL: "@cf/test/model", AI: { run: vi.fn() },
    } as unknown as Env;
    const { service } = fixture(env);
    const intent = parseModelManagementIntent("Workers AI의 @cf/test/model 모델로 변경해", service)!;
    expect(intent).toEqual({ toolName: "model.set_active", arguments: { provider: "workers-ai", model: "@cf/test/model" } });
    const tool = createModelManagementTools(service).find((candidate) => candidate.name === intent.toolName)!;
    await tool.execute(intent.arguments, { timezone: "Asia/Seoul" });
    expect(service.getActive()).toMatchObject({ provider: "workers-ai", model: "@cf/test/model" });
  });

  it("keeps Qwen as default while allowing another registered Workers AI model", () => {
    const env = {
      LLM_PROVIDER: "workers-ai", LLM_MODEL: DEFAULT_WORKERS_AI_MODEL,
      WORKERS_AI_MODEL: "@cf/meta/llama-3.3-70b-instruct-fp8-fast", AI: { run: vi.fn() },
    } as unknown as Env;
    const { service } = fixture(env);

    service.setActive("workers-ai", "@cf/meta/llama-3.3-70b-instruct-fp8-fast");
    expect(service.getActive()).toMatchObject({ model: "@cf/meta/llama-3.3-70b-instruct-fp8-fast", isDefault: false });
    expect(service.getDefault()).toMatchObject({ model: DEFAULT_WORKERS_AI_MODEL, isDefault: true });
  });

  it("rejects unknown or disabled models without changing the stored selection", () => {
    const env = { LLM_PROVIDER: "openai", LLM_MODEL: "gpt-test", OPENAI_API_KEY: "secret" } as Env;
    const { service, getRow } = fixture(env);
    const original = service.setActive("openai", "gpt-test");
    expect(() => service.setActive("workers-ai", "@cf/unknown/model")).toThrow("등록되지 않은 모델");
    expect(service.getActive()).toMatchObject({ provider: original.provider, model: original.model });
    expect(getRow()).toMatchObject({ provider: "openai", model_id: "gpt-test" });
  });

  it("does not mutate active configuration when Workers AI inference fails", async () => {
    const env = {
      LLM_PROVIDER: "workers-ai", LLM_MODEL: "@cf/test/model", WORKERS_AI_MODEL: "@cf/test/model",
      AI: { run: vi.fn().mockRejectedValue(new Error("inference failed")) },
    } as unknown as Env;
    const { service, getRow } = fixture(env);
    service.setActive("workers-ai", "@cf/test/model");
    const provider = createModelProvider(env, service.getActive());
    await expect(provider.generate({ systemPrompt: "help", messages: [{ role: "user", content: "hello" }] })).rejects.toThrow();
    expect(getRow()).toMatchObject({ provider: "workers-ai", model_id: "@cf/test/model" });
  });

  it("keeps the default immutable and explicitly resets the persisted active model", () => {
    const env = {
      LLM_PROVIDER: "workers-ai", LLM_MODEL: DEFAULT_WORKERS_AI_MODEL,
      WORKERS_AI_MODEL: DEFAULT_WORKERS_AI_MODEL, AI: { run: vi.fn() },
      OPENAI_MODEL: "gpt-test", OPENAI_API_KEY: "secret",
    } as unknown as Env;
    const { service, getRow } = fixture(env);

    service.setActive("openai", "gpt-test");
    expect(service.getActive()).toMatchObject({ provider: "openai", isDefault: false, source: "persistent" });
    expect(service.getDefault()).toMatchObject({ provider: "workers-ai", model: DEFAULT_WORKERS_AI_MODEL });

    service.resetToDefault();
    expect(service.getActive()).toMatchObject({
      provider: "workers-ai", model: DEFAULT_WORKERS_AI_MODEL, isDefault: true, source: "persistent",
    });
    expect(getRow()).toMatchObject({ provider: "workers-ai", model_id: DEFAULT_WORKERS_AI_MODEL });
  });

  it("maps default model queries and reset commands to management tools", () => {
    const env = {
      LLM_PROVIDER: "workers-ai", LLM_MODEL: DEFAULT_WORKERS_AI_MODEL,
      WORKERS_AI_MODEL: DEFAULT_WORKERS_AI_MODEL, AI: { run: vi.fn() },
    } as unknown as Env;
    const { service } = fixture(env);

    expect(parseModelManagementIntent("기본 모델이 뭐야?", service)).toEqual({ toolName: "model.get_default", arguments: {} });
    expect(parseModelManagementIntent("기본 모델로 되돌려.", service)).toEqual({ toolName: "model.reset_active", arguments: {} });
    expect(createModelManagementTools(service).map((tool) => tool.name)).toEqual(expect.arrayContaining([
      "model.get_active", "model.get_default", "model.list_available", "model.set_active", "model.reset_active",
    ]));
  });
});
