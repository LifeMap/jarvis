import type { ToolProviderConfigurationService } from "./tool-provider-configuration-service";
import type { DynamicToolProviderId, DynamicToolService } from "./tool-provider-registry";

export type ActiveToolProviders = Record<DynamicToolService, DynamicToolProviderId>;

export class ToolProviderResolver {
  constructor(private readonly configuration: ToolProviderConfigurationService) {}
  resolve(service: DynamicToolService): DynamicToolProviderId { return this.configuration.getActive(service).providerId; }
  resolveAll(): ActiveToolProviders {
    return { gmail: this.resolve("gmail"), calendar: this.resolve("calendar"), search: this.resolve("search") };
  }
}
