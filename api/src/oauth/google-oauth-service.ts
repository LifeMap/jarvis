import type { Env } from "../env";
import type { GoogleOAuthStore, GoogleToken } from "./google-oauth-repository";
import { safeErrorMessage } from "../security/redaction";

const GOOGLE_SCOPES = [
  "https://www.googleapis.com/auth/gmail.readonly",
  "https://www.googleapis.com/auth/gmail.send",
  "https://www.googleapis.com/auth/calendar.events",
];

interface TokenResponse {
  access_token?: string;
  refresh_token?: string;
  token_type?: string;
  scope?: string;
  expires_in?: number;
  error?: string;
  error_description?: string;
}

export class GoogleOAuthService {
  constructor(
    private readonly repository: GoogleOAuthStore,
    private readonly env: Env,
    private readonly fetcher: typeof fetch = (input, init) => fetch(input, init),
  ) {}

  createAuthorizationUrl(redirectUri: string): string {
    const clientId = this.requireConfig("GOOGLE_CLIENT_ID", this.env.GOOGLE_CLIENT_ID);
    const state = randomState();
    this.repository.createState(state, redirectUri);
    const url = new URL("https://accounts.google.com/o/oauth2/v2/auth");
    url.search = new URLSearchParams({
      client_id: clientId,
      redirect_uri: redirectUri,
      response_type: "code",
      scope: GOOGLE_SCOPES.join(" "),
      access_type: "offline",
      include_granted_scopes: "true",
      prompt: "consent",
      state,
    }).toString();
    return url.toString();
  }

  async completeAuthorization(code: string, state: string): Promise<void> {
    const redirectUri = this.repository.consumeState(state);
    if (!redirectUri) throw new Error("OAuth state가 유효하지 않거나 만료되었습니다.");
    const payload = await this.requestToken({
      code,
      redirect_uri: redirectUri,
      grant_type: "authorization_code",
    });
    this.repository.saveToken(toToken(payload, null));
  }

  async getAccessToken(): Promise<string> {
    const token = this.repository.getToken();
    if (!token) throw new Error("Google 계정이 연결되지 않았습니다.");
    if (token.expiresAt > Date.now() + 60_000) return token.accessToken;
    if (!token.refreshToken) throw new Error("Google refresh token이 없어 다시 연결해야 합니다.");
    try {
      const payload = await this.requestToken({ refresh_token: token.refreshToken, grant_type: "refresh_token" });
      const refreshed = toToken(payload, token);
      this.repository.saveToken(refreshed);
      return refreshed.accessToken;
    } catch(error) {
      this.repository.updateStatus?.("refresh-failed",safeErrorMessage(error,"Google OAuth 갱신에 실패했습니다."));
      throw new Error("Google 인증 갱신에 실패했습니다. 계정을 다시 연결해 주세요.");
    }
  }

  status() {
    const token = this.repository.getToken();
    const lifecycle=!token?"authorization-required":token.expiresAt<=Date.now()?token.refreshToken?"expiring":"expired":token.expiresAt<=Date.now()+5*60_000?"expiring":"valid";
    return {
      connected: Boolean(token),
      status:lifecycle,
      credentialRef:"google-oauth-main",
      scopes: token?.scope.split(" ").filter(Boolean) ?? [],
      expiresAt: token ? new Date(token.expiresAt).toISOString() : null,
      hasRefreshToken: Boolean(token?.refreshToken),
    };
  }

  disconnect(): boolean { return this.repository.deleteToken(); }

  private async requestToken(parameters: Record<string, string>): Promise<TokenResponse> {
    const clientId = this.requireConfig("GOOGLE_CLIENT_ID", this.env.GOOGLE_CLIENT_ID);
    const clientSecret = this.requireConfig("GOOGLE_CLIENT_SECRET", this.env.GOOGLE_CLIENT_SECRET);
    const response = await this.fetcher("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ client_id: clientId, client_secret: clientSecret, ...parameters }),
    });
    const payload = await response.json() as TokenResponse;
    if (!response.ok || !payload.access_token) {
      throw new Error(`Google OAuth token 요청 실패: ${safeErrorMessage(payload.error_description ?? payload.error ?? String(response.status))}`);
    }
    return payload;
  }

  private requireConfig(name: string, value?: string): string {
    if (!value) throw new Error(`${name} Secret이 설정되지 않았습니다.`);
    return value;
  }
}

function toToken(payload: TokenResponse, previous: GoogleToken | null): GoogleToken {
  return {
    accessToken: payload.access_token!,
    refreshToken: payload.refresh_token ?? previous?.refreshToken ?? null,
    tokenType: payload.token_type ?? previous?.tokenType ?? "Bearer",
    scope: payload.scope ?? previous?.scope ?? GOOGLE_SCOPES.join(" "),
    expiresAt: Date.now() + (payload.expires_in ?? 3600) * 1000,
  };
}

function randomState(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
