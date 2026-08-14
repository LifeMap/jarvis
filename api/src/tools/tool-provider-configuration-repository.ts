import type { SqlExecutor } from "../storage/sql";
import type { DynamicToolProviderId, DynamicToolService, ToolProviderSelection } from "./tool-provider-registry";

interface Row { service: string; provider_id: string; updated_at: string }

export class ToolProviderConfigurationRepository {
  constructor(private readonly database: SqlExecutor) {}

  get(service: DynamicToolService): (ToolProviderSelection & { updatedAt: string }) | null {
    const [row] = this.database.sql<Row>`SELECT service, provider_id, updated_at FROM tool_provider_configuration WHERE service = ${service}`;
    if (!row || !isService(row.service) || !isProvider(row.provider_id)) return null;
    return { service: row.service, providerId: row.provider_id, updatedAt: row.updated_at };
  }

  set(selection: ToolProviderSelection): ToolProviderSelection & { updatedAt: string } {
    const updatedAt = new Date().toISOString();
    this.database.sql`
      INSERT INTO tool_provider_configuration (service, provider_id, updated_at)
      VALUES (${selection.service}, ${selection.providerId}, ${updatedAt})
      ON CONFLICT(service) DO UPDATE SET provider_id = excluded.provider_id, updated_at = excluded.updated_at
    `;
    return { ...selection, updatedAt };
  }
}

function isService(value: string): value is DynamicToolService { return value === "gmail" || value === "calendar" || value === "search"; }
function isProvider(value: string): value is DynamicToolProviderId {
  return /^[a-z0-9][a-z0-9_-]{0,63}$/i.test(value);
}
