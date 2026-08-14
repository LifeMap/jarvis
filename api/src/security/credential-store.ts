import type { SqlExecutor } from "../storage/sql";
import { redactText } from "./redaction";

export type CredentialStatus = "not-configured" | "authorization-required" | "valid" | "expiring" | "expired" | "refresh-failed" | "revoked" | "error";
export interface CredentialMetadata { ref: string; type: "oauth" | "api-key" | "bearer"; provider: string; status: CredentialStatus; scopes: string[]; expiresAt: number | null; lastError?: string; updatedAt: string }
export interface StoredCredential { value: Record<string, unknown>; metadata: CredentialMetadata }
interface Row { credential_ref:string;secret_json:string;type:CredentialMetadata["type"];provider:string;status:CredentialStatus;scopes_json:string;expires_at:number|null;last_error:string|null;updated_at:string }

export interface CredentialStore {
  getCredential(ref:string):StoredCredential|undefined;
  setCredential(ref:string,value:Record<string,unknown>,metadata:Omit<CredentialMetadata,"ref"|"updatedAt">):CredentialMetadata;
  deleteCredential(ref:string):boolean;
  hasCredential(ref:string):boolean;
  getCredentialMetadata(ref:string):CredentialMetadata|undefined;
  listCredentialMetadata():CredentialMetadata[];
  updateCredentialStatus(ref:string,status:CredentialStatus,lastError?:string):CredentialMetadata|undefined;
}

/** Runtime secrets are isolated from configuration tables and never returned by metadata APIs. */
export class DurableObjectCredentialStore implements CredentialStore {
  constructor(private readonly db:SqlExecutor) {}
  getCredential(ref:string):StoredCredential|undefined { const row=this.row(ref);return row?{value:JSON.parse(row.secret_json) as Record<string,unknown>,metadata:metadata(row)}:undefined; }
  setCredential(ref:string,value:Record<string,unknown>,input:Omit<CredentialMetadata,"ref"|"updatedAt">):CredentialMetadata { const now=new Date().toISOString();this.db.sql`INSERT INTO runtime_credentials (credential_ref,secret_json,type,provider,status,scopes_json,expires_at,last_error,created_at,updated_at) VALUES (${ref},${JSON.stringify(value)},${input.type},${input.provider},${input.status},${JSON.stringify(input.scopes)},${input.expiresAt},${input.lastError?redactText(input.lastError):null},${now},${now}) ON CONFLICT(credential_ref) DO UPDATE SET secret_json=excluded.secret_json,type=excluded.type,provider=excluded.provider,status=excluded.status,scopes_json=excluded.scopes_json,expires_at=excluded.expires_at,last_error=excluded.last_error,updated_at=excluded.updated_at`;return this.getCredentialMetadata(ref)!; }
  deleteCredential(ref:string):boolean { return this.db.sql<{credential_ref:string}>`DELETE FROM runtime_credentials WHERE credential_ref=${ref} RETURNING credential_ref`.length>0; }
  hasCredential(ref:string){return Boolean(this.row(ref));}
  getCredentialMetadata(ref:string){const row=this.row(ref);return row?metadata(row):undefined;}
  listCredentialMetadata(){return this.db.sql<Row>`SELECT credential_ref,secret_json,type,provider,status,scopes_json,expires_at,last_error,updated_at FROM runtime_credentials ORDER BY credential_ref`.map(metadata);}
  updateCredentialStatus(ref:string,status:CredentialStatus,lastError?:string){const now=new Date().toISOString();this.db.sql`UPDATE runtime_credentials SET status=${status},last_error=${lastError?redactText(lastError):null},updated_at=${now} WHERE credential_ref=${ref}`;return this.getCredentialMetadata(ref);}
  private row(ref:string){const[row]=this.db.sql<Row>`SELECT credential_ref,secret_json,type,provider,status,scopes_json,expires_at,last_error,updated_at FROM runtime_credentials WHERE credential_ref=${ref}`;return row;}
}
function metadata(row:Row):CredentialMetadata{return{ref:row.credential_ref,type:row.type,provider:row.provider,status:row.status,scopes:JSON.parse(row.scopes_json) as string[],expiresAt:row.expires_at,updatedAt:row.updated_at,...(row.last_error?{lastError:row.last_error}:{})}}
