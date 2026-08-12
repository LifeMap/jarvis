import type { ConversationMessage, ConversationSummary, MessageRole } from "../contracts";
import type { SqlExecutor } from "../storage/sql";

interface MessageRow {
  message_id: string;
  session_id: string;
  role: MessageRole;
  content: string;
  model: string | null;
  tool_calls_json: string | null;
  tool_result_json: string | null;
  created_at: string;
}

export class ConversationRepository {
  constructor(private readonly database: SqlExecutor) {}

  ensureSession(sessionId: string, now = new Date().toISOString()): void {
    this.database.sql`
      INSERT INTO conversations (session_id, created_at, updated_at)
      VALUES (${sessionId}, ${now}, ${now})
      ON CONFLICT(session_id) DO UPDATE SET updated_at = excluded.updated_at
    `;
  }

  addMessage(input: {
    sessionId: string;
    role: MessageRole;
    content: string;
    model?: string;
    toolCalls?: unknown[];
    toolResult?: unknown;
  }): ConversationMessage {
    const messageId = crypto.randomUUID();
    const createdAt = new Date().toISOString();
    const model = input.model ?? null;
    const toolCallsJson = input.toolCalls ? JSON.stringify(input.toolCalls) : null;
    const toolResultJson = input.toolResult === undefined ? null : JSON.stringify(input.toolResult);
    this.ensureSession(input.sessionId, createdAt);
    this.database.sql`
      INSERT INTO messages (
        message_id, session_id, role, content, model, tool_calls_json, tool_result_json, created_at
      ) VALUES (
        ${messageId}, ${input.sessionId}, ${input.role}, ${input.content}, ${model},
        ${toolCallsJson}, ${toolResultJson}, ${createdAt}
      )
    `;
    return {
      messageId,
      sessionId: input.sessionId,
      role: input.role,
      content: input.content,
      model,
      toolCalls: input.toolCalls ?? null,
      toolResult: input.toolResult ?? null,
      createdAt,
    };
  }

  listMessages(sessionId: string, limit = 100): ConversationMessage[] {
    return this.database.sql<MessageRow>`
      SELECT message_id, session_id, role, content, model, tool_calls_json, tool_result_json, created_at
      FROM messages WHERE session_id = ${sessionId}
      ORDER BY created_at ASC LIMIT ${limit}
    `.map(mapMessage);
  }

  recentContext(sessionId: string, limit = 20): ConversationMessage[] {
    return this.database.sql<MessageRow>`
      SELECT message_id, session_id, role, content, model, tool_calls_json, tool_result_json, created_at
      FROM messages WHERE session_id = ${sessionId}
      ORDER BY created_at DESC LIMIT ${limit}
    `.reverse().map(mapMessage);
  }

  listSessions(): ConversationSummary[] {
    return this.database.sql<{
      session_id: string;
      created_at: string;
      updated_at: string;
      message_count: number;
    }>`
      SELECT c.session_id, c.created_at, c.updated_at, COUNT(m.message_id) AS message_count
      FROM conversations c LEFT JOIN messages m ON m.session_id = c.session_id
      GROUP BY c.session_id ORDER BY c.updated_at DESC
    `.map((row) => ({
      sessionId: row.session_id,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
      messageCount: row.message_count,
    }));
  }

  deleteSession(sessionId: string): boolean {
    this.database.sql`DELETE FROM messages WHERE session_id = ${sessionId}`;
    const result = this.database.sql<{ changes: number }>`
      DELETE FROM conversations WHERE session_id = ${sessionId} RETURNING 1 AS changes
    `;
    return result.length > 0;
  }
}

function mapMessage(row: MessageRow): ConversationMessage {
  return {
    messageId: row.message_id,
    sessionId: row.session_id,
    role: row.role,
    content: row.content,
    model: row.model,
    toolCalls: parseJson(row.tool_calls_json),
    toolResult: parseJson(row.tool_result_json),
    createdAt: row.created_at,
  };
}

function parseJson(value: string | null): unknown {
  if (value === null) return null;
  try { return JSON.parse(value) as unknown; } catch { return null; }
}
