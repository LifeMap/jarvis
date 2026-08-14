import type { SqlExecutor } from "../storage/sql";
import { DurableObjectCredentialStore, type CredentialStatus, type CredentialStore } from "../security/credential-store";

export const GOOGLE_CREDENTIAL_REF = "google-oauth-main";

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
  updateStatus?(status:CredentialStatus,error?:string):void;
}

export class GoogleOAuthRepository implements GoogleOAuthStore {
  private readonly credentials:CredentialStore;
  constructor(private readonly database: SqlExecutor,credentials?:CredentialStore) {this.credentials=credentials??new DurableObjectCredentialStore(database);}

  getToken(): GoogleToken | null {
    const stored=this.credentials.getCredential(GOOGLE_CREDENTIAL_REF);
    if(stored){const value=stored.value;return{accessToken:String(value.accessToken),refreshToken:typeof value.refreshToken==="string"?value.refreshToken:null,tokenType:String(value.tokenType??"Bearer"),scope:String(value.scope??""),expiresAt:Number(value.expiresAt)};}
    const [row] = this.database.sql<{
      access_token: string; refresh_token: string | null; token_type: string; scope: string; expires_at: number;
    }>`SELECT access_token, refresh_token, token_type, scope, expires_at FROM google_oauth_tokens WHERE provider = 'google'`;
    const legacy=row ? {
      accessToken: row.access_token,
      refreshToken: row.refresh_token,
      tokenType: row.token_type,
      scope: row.scope,
      expiresAt: row.expires_at,
    } : null;
    if(legacy){this.saveToken(legacy);this.database.sql`DELETE FROM google_oauth_tokens WHERE provider='google'`;}
    return legacy;
  }

  saveToken(token: GoogleToken): void {
    this.credentials.setCredential(GOOGLE_CREDENTIAL_REF,{accessToken:token.accessToken,refreshToken:token.refreshToken,tokenType:token.tokenType,scope:token.scope,expiresAt:token.expiresAt},{type:"oauth",provider:"google",status:token.expiresAt<=Date.now()?"expired":token.expiresAt<=Date.now()+5*60_000?"expiring":"valid",scopes:token.scope.split(" ").filter(Boolean),expiresAt:token.expiresAt});
  }

  deleteToken(): boolean {
    const deleted=this.credentials.deleteCredential(GOOGLE_CREDENTIAL_REF);this.database.sql`DELETE FROM google_oauth_tokens WHERE provider='google'`;return deleted;
  }

  updateStatus(status:CredentialStatus,error?:string){this.credentials.updateCredentialStatus(GOOGLE_CREDENTIAL_REF,status,error);}

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
