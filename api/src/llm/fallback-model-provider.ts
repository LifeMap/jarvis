import type { FallbackConfigurationService } from "../runtime/fallback-configuration";
import { classifyProviderFailure } from "../runtime/provider-health";
import type { ProviderHealthService } from "../runtime/provider-health-service";
import type { LlmRequest, LlmResponse, LlmToolCall, LlmToolDefinition, ModelProvider } from "./types";

interface WrappedContinuation { usedFallback: boolean; inner: unknown }

/** Executes the configured fallback once without mutating the active model. */
export class FallbackModelProvider implements ModelProvider {
  readonly providerId;
  readonly modelId;

  constructor(
    private readonly primary: ModelProvider,
    private readonly fallback: ModelProvider,
    private readonly configuration: FallbackConfigurationService,
    private readonly health: ProviderHealthService,
  ) {
    this.providerId = primary.providerId;
    this.modelId = primary.modelId;
  }

  generate(request: LlmRequest) {
    return this.run((provider) => provider.generate(request));
  }

  async selectTool(request: LlmRequest, tools: LlmToolDefinition[]): Promise<LlmToolCall | null> {
    const outcome = await this.runWithSource((provider) => provider.selectTool(request, tools));
    return outcome.value ? {
      ...outcome.value,
      continuation: { usedFallback: outcome.usedFallback, inner: outcome.value.continuation } satisfies WrappedContinuation,
    } : null;
  }

  async generateWithToolResult(request: LlmRequest, call: LlmToolCall, result: unknown): Promise<LlmResponse> {
    const wrapped = call.continuation as WrappedContinuation | undefined;
    if (wrapped?.usedFallback) {
      return this.fallback.generateWithToolResult(request, { ...call, continuation: wrapped.inner }, result);
    }
    try {
      const started = Date.now();
      const response = await this.primary.generateWithToolResult(request, { ...call, continuation: wrapped?.inner }, result);
      this.health.markSuccess(this.primaryTarget, Date.now() - started);
      return response;
    } catch (error) {
      const failure = classifyProviderFailure(error);
      if (failure.fallbackEligible) this.health.markFailure(this.primaryTarget, failure.type);
      if (!failure.fallbackEligible) throw error;
      try {
        const fallbackStarted = Date.now();
        const response = await this.fallback.generate({
          ...request,
          messages: [...request.messages, { role: "assistant", content: `Tool ${call.name} returned: ${JSON.stringify(result)}. Answer using this result.` }],
        });
        this.health.markSuccess(this.fallbackTarget, Date.now() - fallbackStarted);
        this.configuration.event("model", this.primaryLabel, this.fallbackLabel, failure, "success");
        return response;
      } catch (fallbackError) {
        this.health.markFailure(this.fallbackTarget, classifyProviderFailure(fallbackError).type);
        this.configuration.event("model", this.primaryLabel, this.fallbackLabel, failure, "failed");
        throw fallbackError;
      }
    }
  }

  private async run<T>(call: (provider: ModelProvider) => Promise<T>): Promise<T> {
    return (await this.runWithSource(call)).value;
  }

  private async runWithSource<T>(call: (provider: ModelProvider) => Promise<T>): Promise<{ value: T; usedFallback: boolean }> {
    const started = Date.now();
    try {
      const value = await call(this.primary);
      this.health.markSuccess(this.primaryTarget, Date.now() - started);
      return { value, usedFallback: false };
    } catch (error) {
      const failure = classifyProviderFailure(error);
      if (failure.fallbackEligible) this.health.markFailure(this.primaryTarget, failure.type, Date.now() - started);
      if (!failure.fallbackEligible) throw error;
      try {
        const fallbackStarted = Date.now();
        const value = await call(this.fallback);
        this.health.markSuccess(this.fallbackTarget, Date.now() - fallbackStarted);
        this.configuration.event("model", this.primaryLabel, this.fallbackLabel, failure, "success");
        return { value, usedFallback: true };
      } catch (fallbackError) {
        this.configuration.event("model", this.primaryLabel, this.fallbackLabel, failure, "failed");
        throw fallbackError;
      }
    }
  }

  private get primaryTarget() { return `model.${this.primary.providerId}.${this.primary.modelId}`; }
  private get fallbackTarget() { return `model.${this.fallback.providerId}.${this.fallback.modelId}`; }
  private get primaryLabel() { return `${this.primary.providerId}/${this.primary.modelId}`; }
  private get fallbackLabel() { return `${this.fallback.providerId}/${this.fallback.modelId}`; }
}
