import type { SqlExecutor } from "../storage/sql";

export class ToolExecutionRepository {
  constructor(private readonly database: SqlExecutor) {}

  record(input: {
    id: string;
    requestId: string;
    toolName: string;
    toolInput: Record<string, unknown>;
    success: boolean;
    durationMs: number;
    resultSummary: string;
    error?: string;
  }): void {
    const error = input.error ?? null;
    this.database.sql`
      INSERT INTO tool_executions (
        id, request_id, tool_name, input_json, success, execution_time_ms,
        result_summary, error_message, created_at
      ) VALUES (
        ${input.id}, ${input.requestId}, ${input.toolName}, ${JSON.stringify(sanitizeInput(input.toolInput))},
        ${input.success ? 1 : 0}, ${input.durationMs}, ${input.resultSummary}, ${error}, ${new Date().toISOString()}
      )
    `;
  }

  list(limit = 100) {
    return this.database.sql<{
      id: string; request_id: string; tool_name: string; input_json: string; success: number;
      execution_time_ms: number; result_summary: string; error_message: string | null; created_at: string;
    }>`
      SELECT id, request_id, tool_name, input_json, success, execution_time_ms,
             result_summary, error_message, created_at
      FROM tool_executions ORDER BY created_at DESC LIMIT ${limit}
    `.map((row) => ({
      id: row.id,
      requestId: row.request_id,
      toolName: row.tool_name,
      input: JSON.parse(row.input_json) as Record<string, unknown>,
      success: Boolean(row.success),
      executionTimeMs: row.execution_time_ms,
      resultSummary: row.result_summary,
      error: row.error_message,
      createdAt: row.created_at,
    }));
  }
}

function sanitizeInput(input: Record<string, unknown>): Record<string, unknown> {
  return sanitizeObject(input);
}
function sanitizeObject(input: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(input).map(([key, value]) => {
    const normalized = key.toLowerCase().replace(/[^a-z]/g, "");
    if (["token", "accesstoken", "refreshtoken", "apikey", "authorization", "secret", "clientsecret"].includes(normalized)) {
      return [key, "[REDACTED]"];
    }
    if (["body", "description"].includes(normalized) && typeof value === "string") return [key, `[REDACTED ${value.length} chars]`];
    if (Array.isArray(value)) return [key, value.map((item) => item && typeof item === "object" ? sanitizeObject(item as Record<string, unknown>) : item)];
    if (value && typeof value === "object") return [key, sanitizeObject(value as Record<string, unknown>)];
    return [key, value];
  }));
}
