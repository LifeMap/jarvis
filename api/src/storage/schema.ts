import type { SqlExecutor } from "./sql";

export function ensureApplicationSchema(database: SqlExecutor): void {
  database.sql`
    CREATE TABLE IF NOT EXISTS agent_runs (
      id TEXT PRIMARY KEY,
      request TEXT NOT NULL,
      response TEXT,
      model TEXT,
      status TEXT NOT NULL CHECK (status IN ('pending', 'completed', 'failed')),
      error_message TEXT,
      execution_time_ms INTEGER,
      created_at TEXT NOT NULL,
      completed_at TEXT
    )
  `;
  database.sql`
    CREATE TABLE IF NOT EXISTS conversations (
      session_id TEXT PRIMARY KEY,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  `;
  database.sql`
    CREATE TABLE IF NOT EXISTS messages (
      message_id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system', 'tool')),
      content TEXT NOT NULL,
      model TEXT,
      tool_calls_json TEXT,
      tool_result_json TEXT,
      created_at TEXT NOT NULL
    )
  `;
  database.sql`CREATE INDEX IF NOT EXISTS messages_session_created_idx ON messages (session_id, created_at)`;
  database.sql`
    CREATE TABLE IF NOT EXISTS model_configuration (
      id TEXT PRIMARY KEY CHECK (id = 'active'),
      provider TEXT NOT NULL CHECK (provider IN ('workers-ai', 'openai', 'test')),
      model_id TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  `;
  database.sql`
    CREATE TABLE IF NOT EXISTS tool_provider_configuration (
      service TEXT PRIMARY KEY CHECK (service IN ('gmail', 'calendar', 'search')),
      provider_id TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  `;
  database.sql`
    CREATE TABLE IF NOT EXISTS mcp_server_configuration (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      endpoint TEXT NOT NULL,
      transport TEXT NOT NULL CHECK (transport IN ('streamable-http', 'sse', 'auto')),
      enabled INTEGER NOT NULL,
      auth_type TEXT NOT NULL CHECK (auth_type IN ('none', 'oauth', 'bearer', 'api-key')),
      credential_reference TEXT,
      service TEXT CHECK (service IS NULL OR service IN ('gmail', 'calendar', 'search')),
      provider_id TEXT,
      description TEXT,
      capability_mapping_json TEXT NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  `;
  database.sql`
    CREATE TABLE IF NOT EXISTS profile_memories (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL,
      source TEXT NOT NULL CHECK (source IN ('user', 'agent', 'system')),
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  `;
  database.sql`
    CREATE TABLE IF NOT EXISTS long_term_memories (
      id TEXT PRIMARY KEY,
      content TEXT NOT NULL,
      category TEXT NOT NULL,
      source TEXT NOT NULL CHECK (source IN ('user', 'agent', 'system')),
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  `;
  database.sql`CREATE INDEX IF NOT EXISTS long_term_memories_updated_idx ON long_term_memories (updated_at)`;
  database.sql`
    CREATE TABLE IF NOT EXISTS google_oauth_tokens (
      provider TEXT PRIMARY KEY,
      access_token TEXT NOT NULL,
      refresh_token TEXT,
      token_type TEXT NOT NULL,
      scope TEXT NOT NULL,
      expires_at INTEGER NOT NULL,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
  `;
  database.sql`
    CREATE TABLE IF NOT EXISTS oauth_states (
      state TEXT PRIMARY KEY,
      redirect_uri TEXT NOT NULL,
      expires_at INTEGER NOT NULL,
      created_at TEXT NOT NULL
    )
  `;
  database.sql`
    CREATE TABLE IF NOT EXISTS tool_executions (
      id TEXT PRIMARY KEY,
      request_id TEXT NOT NULL,
      tool_name TEXT NOT NULL,
      input_json TEXT NOT NULL,
      success INTEGER NOT NULL,
      execution_time_ms INTEGER NOT NULL,
      result_summary TEXT NOT NULL,
      error_message TEXT,
      created_at TEXT NOT NULL
    )
  `;
  database.sql`CREATE INDEX IF NOT EXISTS tool_executions_created_idx ON tool_executions (created_at)`;
  database.sql`
    CREATE TABLE IF NOT EXISTS approvals (
      approval_id TEXT PRIMARY KEY,
      conversation_id TEXT NOT NULL,
      request_id TEXT NOT NULL,
      tool_call_id TEXT NOT NULL,
      tool_name TEXT NOT NULL,
      tool_arguments_json TEXT NOT NULL,
      policy TEXT NOT NULL CHECK (policy IN ('APPROVAL_REQUIRED')),
      status TEXT NOT NULL CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED', 'EXECUTED', 'FAILED', 'EXPIRED')),
      requested_at TEXT NOT NULL,
      expires_at TEXT,
      resolved_at TEXT,
      executed_at TEXT,
      result_summary TEXT,
      error_message TEXT,
      execution_id TEXT
    )
  `;
  database.sql`CREATE INDEX IF NOT EXISTS approvals_status_requested_idx ON approvals (status, requested_at)`;
  database.sql`
    CREATE TABLE IF NOT EXISTS schedules (
      id TEXT PRIMARY KEY, title TEXT NOT NULL, instruction TEXT NOT NULL,
      schedule_type TEXT NOT NULL CHECK (schedule_type IN ('one_time', 'recurring')),
      schedule_rule_json TEXT NOT NULL, timezone TEXT NOT NULL, enabled INTEGER NOT NULL,
      status TEXT NOT NULL CHECK (status IN ('scheduled', 'running', 'completed', 'failed', 'disabled')),
      native_schedule_id TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
      last_run_at TEXT, next_run_at TEXT, last_result TEXT
    )
  `;
  database.sql`CREATE INDEX IF NOT EXISTS schedules_next_run_idx ON schedules (enabled, next_run_at)`;
  database.sql`
    CREATE TABLE IF NOT EXISTS schedule_executions (
      id TEXT PRIMARY KEY, schedule_id TEXT NOT NULL, trigger_type TEXT NOT NULL CHECK (trigger_type IN ('manual', 'scheduled')),
      started_at TEXT NOT NULL, completed_at TEXT, success INTEGER, tool_calls_json TEXT,
      response TEXT, error_message TEXT
    )
  `;
  database.sql`CREATE INDEX IF NOT EXISTS schedule_executions_schedule_idx ON schedule_executions (schedule_id, started_at)`;
}
