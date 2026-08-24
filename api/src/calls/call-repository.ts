import type { SqlExecutor } from "../storage/sql";
import type { CallCaller, CallDirection, CallRecord, CallStatus, CallTranscriptTurn } from "./types";

interface CallRow {
  id: string;
  status: CallStatus;
  direction: string | null;
  caller_name: string;
  caller_phone: string;
  started_at: string;
  ended_at: string | null;
  transcript_json: string;
  summary: string | null;
  audio_key: string | null;
  updated_at: string;
}

export class CallRepository {
  constructor(private readonly database: SqlExecutor) {}

  create(input: { caller: CallCaller; startedAt: string; direction: CallDirection }): CallRecord {
    const id = `call-${crypto.randomUUID()}`;
    const now = new Date().toISOString();
    this.database.sql`
      INSERT INTO calls (
        id, status, direction, caller_name, caller_phone, started_at, ended_at,
        transcript_json, summary, audio_key, created_at, updated_at
      ) VALUES (
        ${id}, ${"active"}, ${input.direction}, ${input.caller.name}, ${input.caller.phoneNumber},
        ${input.startedAt}, ${null}, ${"[]"}, ${null}, ${null}, ${now}, ${now}
      )
    `;
    return this.get(id)!;
  }

  get(id: string): CallRecord | null {
    const [row] = this.database.sql<CallRow>`
      SELECT id, status, direction, caller_name, caller_phone, started_at, ended_at,
             transcript_json, summary, audio_key, updated_at
      FROM calls WHERE id = ${id}
    `;
    return row ? mapCall(row) : null;
  }

  list(updatedAfter?: string | null): CallRecord[] {
    const rows = this.database.sql<CallRow>`
      SELECT id, status, direction, caller_name, caller_phone, started_at, ended_at,
             transcript_json, summary, audio_key, updated_at
      FROM calls ORDER BY updated_at DESC
    `;
    const mapped = rows.map(mapCall);
    if (!updatedAfter) return mapped;
    const after = Date.parse(updatedAfter);
    if (!Number.isFinite(after)) return mapped;
    return mapped.filter((record) => Date.parse(record.updatedAt) > after);
  }

  setAudioKey(id: string, audioKey: string): CallRecord | null {
    const current = this.get(id);
    if (!current) return null;
    const now = new Date().toISOString();
    this.database.sql`
      UPDATE calls SET audio_key = ${audioKey}, updated_at = ${now} WHERE id = ${id}
    `;
    return this.get(id);
  }

  complete(id: string, input: {
    endedAt: string;
    transcript: CallTranscriptTurn[];
    summary: string | null;
    status: CallStatus;
  }): CallRecord | null {
    const current = this.get(id);
    if (!current) return null;
    const now = new Date().toISOString();
    this.database.sql`
      UPDATE calls
      SET status = ${input.status}, ended_at = ${input.endedAt},
          transcript_json = ${JSON.stringify(input.transcript)}, summary = ${input.summary},
          updated_at = ${now}
      WHERE id = ${id}
    `;
    return this.get(id);
  }
}

function mapCall(row: CallRow): CallRecord {
  return {
    id: row.id,
    status: row.status,
    direction: row.direction === "outgoing" ? "outgoing" : "incoming",
    caller: { name: row.caller_name, phoneNumber: row.caller_phone },
    startedAt: row.started_at,
    endedAt: row.ended_at,
    transcript: parseTranscript(row.transcript_json),
    summary: row.summary,
    audioKey: row.audio_key,
    hasAudio: Boolean(row.audio_key),
    updatedAt: row.updated_at,
  };
}

function parseTranscript(value: string): CallTranscriptTurn[] {
  try {
    const parsed = JSON.parse(value) as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed.filter((item): item is CallTranscriptTurn => {
      return Boolean(item && typeof item === "object"
        && ((item as CallTranscriptTurn).role === "caller" || (item as CallTranscriptTurn).role === "jarvis")
        && typeof (item as CallTranscriptTurn).text === "string");
    });
  } catch {
    return [];
  }
}
