import { ToolError } from "./types";
import type { ToolProviderConfigurationRepository } from "./tool-provider-configuration-repository";
import type {
  DynamicToolProviderId, DynamicToolService, RegisteredToolProvider, ToolProviderRegistry, ToolProviderSelection,
} from "./tool-provider-registry";

export interface ToolProviderState extends ToolProviderSelection {
  enabled: boolean;
  isDefault: boolean;
  source: "persistent" | "default";
  updatedAt: string | null;
  unavailableReason?: string;
}

export class ToolProviderConfigurationService {
  constructor(private readonly repository: ToolProviderConfigurationRepository, readonly registry: ToolProviderRegistry) {}

  getActive(service: DynamicToolService): ToolProviderState {
    const stored = this.repository.get(service);
    const selection = stored ?? this.registry.defaultFor(service);
    return this.state(selection, stored ? "persistent" : "default", stored?.updatedAt ?? null);
  }
  getDefault(service: DynamicToolService): ToolProviderState {
    return this.state(this.registry.defaultFor(service), "default", null);
  }
  list(service?: DynamicToolService): RegisteredToolProvider[] { return this.registry.list(service); }
  listActive(): ToolProviderState[] { return this.registry.services().map((service) => this.getActive(service)); }

  setActive(service: DynamicToolService, providerId: DynamicToolProviderId) {
    const provider = this.registry.get(service, providerId);
    if (!provider) {
      const reason = `${service}에 ${providerId} Provider가 등록되어 있지 않습니다.`;
      throw new ToolError(reason, `${reason} 기존 설정은 유지됩니다.`);
    }
    if (!provider.enabled) {
      const reason = provider.unavailableReason ?? `${providerId} Provider를 사용할 수 없습니다.`;
      throw new ToolError(reason, `${reason} 기존 설정은 유지됩니다.`);
    }
    return this.repository.set({ service, providerId });
  }
  reset(service: DynamicToolService) {
    const defaultProvider = this.getDefault(service);
    if (!defaultProvider.enabled) {
      const reason = defaultProvider.unavailableReason ?? "기본 Provider를 사용할 수 없습니다.";
      throw new ToolError(reason, `${reason} 기존 설정은 유지됩니다.`);
    }
    return this.repository.set(defaultProvider);
  }

  private state(selection: ToolProviderSelection, source: "persistent" | "default", updatedAt: string | null): ToolProviderState {
    const provider = this.registry.get(selection.service, selection.providerId);
    const defaultProvider = this.registry.defaultFor(selection.service);
    return {
      ...selection, enabled: Boolean(provider?.enabled), source, updatedAt,
      isDefault: selection.providerId === defaultProvider.providerId,
      ...(!provider ? { unavailableReason: "활성 Tool Provider가 Registry에 등록되어 있지 않습니다." }
        : provider.unavailableReason ? { unavailableReason: provider.unavailableReason } : {}),
    };
  }
}
