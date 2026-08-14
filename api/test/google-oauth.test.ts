import { describe, expect, it, vi } from "vitest";
import type { Env } from "../src/env";
import type { GoogleOAuthStore, GoogleToken } from "../src/oauth/google-oauth-repository";
import { GoogleOAuthService } from "../src/oauth/google-oauth-service";

class FakeStore implements GoogleOAuthStore {
  token: GoogleToken | null = null;
  state = new Map<string, string>();
  getToken() { return this.token; }
  saveToken(token: GoogleToken) { this.token = token; }
  deleteToken() { const existed = Boolean(this.token); this.token = null; return existed; }
  createState(state: string, redirectUri: string) { this.state.set(state, redirectUri); }
  consumeState(state: string) { const value = this.state.get(state) ?? null; this.state.delete(state); return value; }
  status?:string;
  updateStatus(status:string){this.status=status;}
}

describe("GoogleOAuthService", () => {
  it("requests the minimum read and write offline scopes needed by registered tools", () => {
    const store = new FakeStore();
    const service = new GoogleOAuthService(store, { GOOGLE_CLIENT_ID: "client", GOOGLE_CLIENT_SECRET: "secret" } as Env);
    const url = new URL(service.createAuthorizationUrl("https://example.com/callback"));
    expect(url.searchParams.get("access_type")).toBe("offline");
    expect(url.searchParams.get("scope")).toContain("gmail.readonly");
    expect(url.searchParams.get("scope")).toContain("gmail.send");
    expect(url.searchParams.get("scope")).toContain("calendar.events");
  });

  it("refreshes and persists an expired access token", async () => {
    const store = new FakeStore();
    store.token = { accessToken: "expired", refreshToken: "refresh", tokenType: "Bearer", scope: "scope", expiresAt: 0 };
    const fetcher = vi.fn<typeof fetch>().mockResolvedValue(Response.json({ access_token: "fresh", expires_in: 3600, token_type: "Bearer" }));
    const service = new GoogleOAuthService(store, { GOOGLE_CLIENT_ID: "client", GOOGLE_CLIENT_SECRET: "secret" } as Env, fetcher);
    await expect(service.getAccessToken()).resolves.toBe("fresh");
    expect(store.token?.accessToken).toBe("fresh");
    expect(store.token?.refreshToken).toBe("refresh");
  });

  it("marks refresh failures without exposing token endpoint details", async()=>{
    const store=new FakeStore();store.token={accessToken:"expired",refreshToken:"refresh-secret",tokenType:"Bearer",scope:"scope",expiresAt:0};
    const fetcher=vi.fn<typeof fetch>().mockResolvedValue(Response.json({error:"invalid_grant",error_description:"refresh_token=refresh-secret revoked"},{status:400}));
    const service=new GoogleOAuthService(store,{GOOGLE_CLIENT_ID:"client",GOOGLE_CLIENT_SECRET:"secret"} as Env,fetcher);
    await expect(service.getAccessToken()).rejects.toThrow("다시 연결");
    expect(store.status).toBe("refresh-failed");
    await expect(service.getAccessToken()).rejects.not.toThrow("refresh-secret");
  });
});
