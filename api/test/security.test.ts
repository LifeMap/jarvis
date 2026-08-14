import { describe, expect, it } from "vitest";
import type { SqlExecutor } from "../src/storage/sql";
import { DurableObjectCredentialStore } from "../src/security/credential-store";
import { parseAuthManagementIntent } from "../src/security/auth-management-tools";
import { redactText, redactValue, safeErrorMessage } from "../src/security/redaction";

describe("runtime credential store",()=>{
  it("stores, reads metadata, rotates, and deletes without metadata exposing values",()=>{
    const db=fakeDb(),store=new DurableObjectCredentialStore(db);
    store.setCredential("google-main",{accessToken:"access-secret",refreshToken:"refresh-secret"},{type:"oauth",provider:"google",status:"valid",scopes:["gmail.readonly"],expiresAt:123});
    expect(store.hasCredential("google-main")).toBe(true);
    expect(store.getCredential("google-main")?.value.accessToken).toBe("access-secret");
    expect(JSON.stringify(store.getCredentialMetadata("google-main"))).not.toContain("access-secret");
    expect(JSON.stringify(store.listCredentialMetadata())).not.toContain("refresh-secret");
    store.setCredential("google-main",{accessToken:"rotated"},{type:"oauth",provider:"google",status:"expiring",scopes:["gmail.readonly"],expiresAt:456});
    expect(store.getCredential("google-main")?.value.accessToken).toBe("rotated");
    expect(store.deleteCredential("google-main")).toBe(true);
    expect(store.hasCredential("google-main")).toBe(false);
  });
});

describe("credential redaction",()=>{
  it("removes headers, token fields, query secrets, and common key formats",()=>{
    const text=redactText("Authorization: Bearer abc.def.ghi https://x.test?a=1&api_key=my-secret access_token=token-value sk-abcdefghijklmnopqrstuvwxyz");
    expect(text).not.toContain("abc.def");expect(text).not.toContain("my-secret");expect(text).not.toContain("token-value");expect(text).not.toContain("sk-abcdef");
    const value=redactValue({id:"safe",authorization:"Bearer hidden",nested:{refresh_token:"hidden",message:"ok"}});
    expect(value).toEqual({id:"safe",nested:{message:"ok"}});
    expect(safeErrorMessage(new Error("failed Authorization: Bearer top-secret"))).not.toContain("top-secret");
  });
});

describe("natural auth management",()=>{
  it("requires an explicit mutation verb",()=>{
    expect(parseAuthManagementIntent("Gmail 인증 상태 확인해")?.toolName).toBe("auth.get");
    expect(parseAuthManagementIntent("Gmail 연결해")?.toolName).toBe("auth.begin");
    expect(parseAuthManagementIntent("Gmail 연결 해제해")?.toolName).toBe("auth.disconnect");
    expect(parseAuthManagementIntent("Gmail 연결이 필요한 것 같아")).toBeNull();
  });
});

function fakeDb():SqlExecutor{
  const rows=new Map<string,Record<string,unknown>>();
  const sql:SqlExecutor["sql"]=((strings:TemplateStringsArray,...values:unknown[])=>{
    const query=strings.join("?");
    if(query.includes("INSERT INTO runtime_credentials")){const previous=rows.get(String(values[0]));rows.set(String(values[0]),{credential_ref:values[0],secret_json:values[1],type:values[2],provider:values[3],status:values[4],scopes_json:values[5],expires_at:values[6],last_error:values[7],updated_at:values[9],created_at:previous?.created_at??values[8]});return[];}
    if(query.includes("UPDATE runtime_credentials")){const row=rows.get(String(values[3]));if(row)rows.set(String(values[3]),{...row,status:values[0],last_error:values[1],updated_at:values[2]});return[];}
    if(query.includes("DELETE FROM runtime_credentials")){const key=String(values[0]),row=rows.get(key);rows.delete(key);return row?[{credential_ref:key}]:[];}
    if(query.includes("WHERE credential_ref")){const row=rows.get(String(values[0]));return row?[row]:[];}
    if(query.includes("FROM runtime_credentials"))return[...rows.values()];
    return[];
  }) as SqlExecutor["sql"];
  return{sql};
}
