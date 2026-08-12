import type {
  CreateMemoryInput,
  LongTermMemory,
  MemorySource,
  ProfileMemory,
  UpdateMemoryInput,
} from "../contracts";
import type { SqlExecutor } from "../storage/sql";

interface ProfileRow { key: string; value: string; source: MemorySource; created_at: string; updated_at: string }
interface LongTermRow { id: string; content: string; category: string; source: MemorySource; created_at: string; updated_at: string }

export class MemoryRepository {
  constructor(private readonly database: SqlExecutor) {}

  listProfile(): ProfileMemory[] {
    return this.database.sql<ProfileRow>`
      SELECT key, value, source, created_at, updated_at FROM profile_memories ORDER BY key
    `.map(mapProfile);
  }

  listLongTerm(limit = 100): LongTermMemory[] {
    return this.database.sql<LongTermRow>`
      SELECT id, content, category, source, created_at, updated_at
      FROM long_term_memories ORDER BY updated_at DESC LIMIT ${limit}
    `.map(mapLongTerm);
  }

  create(input: CreateMemoryInput): ProfileMemory | LongTermMemory {
    const now = new Date().toISOString();
    if (input.type === "profile") {
      this.database.sql`
        INSERT INTO profile_memories (key, value, source, created_at, updated_at)
        VALUES (${input.key}, ${input.value}, ${input.source}, ${now}, ${now})
        ON CONFLICT(key) DO UPDATE SET value = excluded.value, source = excluded.source, updated_at = excluded.updated_at
      `;
      return this.getProfile(input.key)!;
    }
    const id = crypto.randomUUID();
    this.database.sql`
      INSERT INTO long_term_memories (id, content, category, source, created_at, updated_at)
      VALUES (${id}, ${input.content}, ${input.category}, ${input.source}, ${now}, ${now})
    `;
    return this.getLongTerm(id)!;
  }

  update(id: string, input: UpdateMemoryInput): ProfileMemory | LongTermMemory | null {
    const now = new Date().toISOString();
    if (id.startsWith("profile:")) {
      const key = id.slice("profile:".length);
      const current = this.getProfile(key);
      if (!current) return null;
      const value = input.value ?? current.value;
      const source = input.source ?? current.source;
      this.database.sql`
        UPDATE profile_memories SET value = ${value}, source = ${source}, updated_at = ${now} WHERE key = ${key}
      `;
      return this.getProfile(key);
    }
    const current = this.getLongTerm(id);
    if (!current) return null;
    const content = input.content ?? current.content;
    const category = input.category ?? current.category;
    const source = input.source ?? current.source;
    this.database.sql`
      UPDATE long_term_memories SET content = ${content}, category = ${category}, source = ${source}, updated_at = ${now}
      WHERE id = ${id}
    `;
    return this.getLongTerm(id);
  }

  delete(id: string): boolean {
    if (id.startsWith("profile:")) {
      const key = id.slice("profile:".length);
      return this.database.sql<{ id: string }>`DELETE FROM profile_memories WHERE key = ${key} RETURNING key AS id`.length > 0;
    }
    return this.database.sql<{ id: string }>`DELETE FROM long_term_memories WHERE id = ${id} RETURNING id`.length > 0;
  }

  private getProfile(key: string): ProfileMemory | null {
    const [row] = this.database.sql<ProfileRow>`
      SELECT key, value, source, created_at, updated_at FROM profile_memories WHERE key = ${key}
    `;
    return row ? mapProfile(row) : null;
  }

  private getLongTerm(id: string): LongTermMemory | null {
    const [row] = this.database.sql<LongTermRow>`
      SELECT id, content, category, source, created_at, updated_at FROM long_term_memories WHERE id = ${id}
    `;
    return row ? mapLongTerm(row) : null;
  }
}

function mapProfile(row: ProfileRow): ProfileMemory {
  return { id: `profile:${row.key}`, type: "profile", key: row.key, value: row.value, source: row.source, createdAt: row.created_at, updatedAt: row.updated_at };
}
function mapLongTerm(row: LongTermRow): LongTermMemory {
  return { id: row.id, type: "long_term", content: row.content, category: row.category, source: row.source, createdAt: row.created_at, updatedAt: row.updated_at };
}
