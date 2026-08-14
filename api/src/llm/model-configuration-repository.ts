import type { SqlExecutor } from "../storage/sql";
import type { ModelProviderId } from "./types";
import type { ModelSelection } from "./model-registry";

interface Row { provider: string; model_id: string; updated_at: string }

export class ModelConfigurationRepository {
  constructor(private readonly database: SqlExecutor) {}

  get(): (ModelSelection & { updatedAt: string }) | null {
    const [row] = this.database.sql<Row>`SELECT provider, model_id, updated_at FROM model_configuration WHERE id = 'active'`;
    if (!row || !isProvider(row.provider)) return null;
    return { provider: row.provider, model: row.model_id, updatedAt: row.updated_at };
  }

  set(selection: ModelSelection): ModelSelection & { updatedAt: string } {
    const updatedAt = new Date().toISOString();
    this.database.sql`
      INSERT INTO model_configuration (id, provider, model_id, updated_at)
      VALUES ('active', ${selection.provider}, ${selection.model}, ${updatedAt})
      ON CONFLICT(id) DO UPDATE SET provider = excluded.provider, model_id = excluded.model_id, updated_at = excluded.updated_at
    `;
    return { ...selection, updatedAt };
  }
}

function isProvider(value: string): value is ModelProviderId {
  return value === "workers-ai" || value === "openai" || value === "test";
}
