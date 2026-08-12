import type { SqlExecutor } from "../storage/sql";

export interface GoogleToken {
  accessToken: string;
  refreshToken: string | null;
  tokenType: string;
  scope: string;
  expiresAt: number;
}

export interface GoogleOAuthStore {
  getToken(): GoogleToken | null;
  saveToken(token: GoogleToken): void;
  deleteToken(): boolean;
  createState(state: string, redirectUri: string): void;
  consumeState(state: string): string | null;
}

export class GoogleOAuthRepository implements GoogleOAuthStore {
  constructor(private readonly database: SqlExecutor) {}

  getToken(): GoogleToken | null {
    const [row] = this.database.sql<{
      access_token: string; refresh_token: string | null; token_type: string; scope: string; expires_at: number;
    }>`SELECT access_token, refresh_token, token_type, scope, expires_at FROM google_oauth_tokens WHERE provider = 'google'`;
    return row ? {
      accessToken: row.access_token,
      refreshToken: row.refresh_token,
      tokenType: row.token_type,
      scope: row.scope,
      expiresAt: row.expires_at,
    } : null;
  }

  saveToken(token: GoogleToken): void {
    const now = new Date().toISOString();
    this.database.sql`
      INSERT INTO google_oauth_tokens (
        provider, access_token, refresh_token, token_type, scope, expires_at, created_at, updated_at
      ) VALUES ('google', ${token.accessToken}, ${token.refreshToken}, ${token.tokenType}, ${token.scope}, ${token.expiresAt}, ${now}, ${now})
      ON CONFLICT(provider) DO UPDATE SET
        access_token = excluded.access_token,
        refresh_token = COALESCE(excluded.refresh_token, google_oauth_tokens.refresh_token),
        token_type = excluded.token_type,
        scope = excluded.scope,
        expires_at = excluded.expires_at,
        updated_at = excluded.updated_at
    `;
  }

  deleteToken(): boolean {
    return this.database.sql<{ provider: string }>`
      DELETE FROM google_oauth_tokens WHERE provider = 'google' RETURNING provider
    `.length > 0;
  }

  createState(state: string, redirectUri: string): void {
    const now = new Date().toISOString();
    const expiresAt = Date.now() + 10 * 60_000;
    this.database.sql`DELETE FROM oauth_states WHERE expires_at < ${Date.now()}`;
    this.database.sql`
      INSERT INTO oauth_states (state, redirect_uri, expires_at, created_at)
      VALUES (${state}, ${redirectUri}, ${expiresAt}, ${now})
    `;
  }

  consumeState(state: string): string | null {
    const [row] = this.database.sql<{ redirect_uri: string; expires_at: number }>`
      DELETE FROM oauth_states WHERE state = ${state} RETURNING redirect_uri, expires_at
    `;
    return row && row.expires_at >= Date.now() ? row.redirect_uri : null;
  }
}
