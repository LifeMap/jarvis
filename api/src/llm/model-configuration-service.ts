import { LlmProviderError, type ModelProviderId } from "./types";
import type { ModelConfigurationRepository } from "./model-configuration-repository";
import type { ModelRegistry, ModelSelection, RegisteredModel } from "./model-registry";

export class ModelConfigurationService {
  constructor(private readonly repository: ModelConfigurationRepository, readonly registry: ModelRegistry) {}

  getActive(): ModelSelection & { enabled: boolean; updatedAt: string | null; unavailableReason?: string } {
    const stored = this.repository.get();
    const selection = stored ?? this.registry.defaultModel;
    const registered = this.registry.get(selection.provider, selection.model);
    return {
      ...selection, enabled: Boolean(registered?.enabled), updatedAt: stored?.updatedAt ?? null,
      ...(!registered ? { unavailableReason: "활성 모델이 Registry에 등록되어 있지 않습니다." }
        : registered.unavailableReason ? { unavailableReason: registered.unavailableReason } : {}),
    };
  }

  listAvailable(): RegisteredModel[] { return this.registry.list(); }

  setActive(provider: ModelProviderId, model?: string): ModelSelection & { updatedAt: string } {
    const registered = model ? this.registry.get(provider, model) : this.registry.defaultForProvider(provider);
    if (!registered) throw new LlmProviderError(`등록되지 않은 모델입니다: ${provider}/${model ?? "default"}`);
    if (!registered.enabled) throw new LlmProviderError(registered.unavailableReason ?? `비활성화된 모델입니다: ${provider}/${registered.model}`);
    return this.repository.set({ provider, model: registered.model });
  }
}
