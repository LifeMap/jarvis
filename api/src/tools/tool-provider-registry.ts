import type { Env } from "../env";

export type DynamicToolService = "gmail" | "calendar" | "search";
export type DynamicToolProviderId = string;

export interface ToolProviderSelection {
  service: DynamicToolService;
  providerId: DynamicToolProviderId;
}

export interface RegisteredToolProvider extends ToolProviderSelection {
  displayName: string;
  enabled: boolean;
  requiresAuth: boolean;
  capabilities: string[];
  unavailableReason?: string;
  type?: "api" | "mcp";
  mcpServerId?: string;
}

export interface ToolProviderAvailability {
  googleConnected: boolean;
  googleScopes?:string[];
}

const DEFAULTS: Record<DynamicToolService, DynamicToolProviderId> = {
  gmail: "gmail-api",
  calendar: "google-calendar-api",
  search: "brave-api",
};

export class ToolProviderRegistry {
  constructor(readonly providers: RegisteredToolProvider[]) {}

  services(): DynamicToolService[] { return ["gmail", "calendar", "search"]; }
  list(service?: DynamicToolService): RegisteredToolProvider[] {
    return this.providers.filter((provider) => !service || provider.service === service)
      .map((provider) => ({ ...provider, capabilities: [...provider.capabilities] }));
  }
  get(service: DynamicToolService, providerId: string): RegisteredToolProvider | undefined {
    return this.providers.find((provider) => provider.service === service && provider.providerId === providerId);
  }
  defaultFor(service: DynamicToolService): ToolProviderSelection {
    return { service, providerId: DEFAULTS[service] };
  }
}

export function createToolProviderRegistry(env: Env, availability: ToolProviderAvailability, dynamic: RegisteredToolProvider[] = []): ToolProviderRegistry {
  const googleConfigured = Boolean(env.GOOGLE_CLIENT_ID && env.GOOGLE_CLIENT_SECRET);
  const googleEnabled = googleConfigured && availability.googleConnected;
  const scopes=availability.googleScopes;
  const gmailCapabilities=!scopes?["read","send","reply"]:[...(scopes.includes("https://www.googleapis.com/auth/gmail.readonly")?["read"]:[]),...(scopes.includes("https://www.googleapis.com/auth/gmail.send")?["send","reply"]:[])];
  const calendarCapabilities=!scopes||scopes.includes("https://www.googleapis.com/auth/calendar.events")?["read","create","update","delete"]:scopes.includes("https://www.googleapis.com/auth/calendar.readonly")?["read"]:[];
  const googleReason = !googleConfigured
    ? "GOOGLE_CLIENT_ID 또는 GOOGLE_CLIENT_SECRET이 설정되지 않았습니다."
    : !availability.googleConnected ? "Google 계정이 연결되지 않았습니다." : undefined;
  return new ToolProviderRegistry([
    provider("gmail", "gmail-api", "Gmail API", googleEnabled&&gmailCapabilities.includes("read"), true, gmailCapabilities, googleReason??(!gmailCapabilities.includes("read")?"Gmail read scope가 없습니다.":undefined)),
    provider("calendar", "google-calendar-api", "Google Calendar API", googleEnabled&&calendarCapabilities.includes("read"), true, calendarCapabilities, googleReason??(!calendarCapabilities.includes("read")?"Calendar read scope가 없습니다.":undefined)),
    provider("search", "brave-api", "Brave Search API", Boolean(env.SEARCH_API_KEY), true, ["search"], env.SEARCH_API_KEY ? undefined : "SEARCH_API_KEY가 설정되지 않았습니다."),
    provider("search", "serpapi", "SerpApi", Boolean(env.SERP_API_KEY), true, ["search"], env.SERP_API_KEY ? undefined : "SERP_API_KEY가 설정되지 않았습니다."),
    ...dynamic,
  ]);
}

function provider(
  service: DynamicToolService, providerId: DynamicToolProviderId, displayName: string,
  enabled: boolean, requiresAuth: boolean, capabilities: string[], unavailableReason?: string,
): RegisteredToolProvider {
  return { service, providerId, displayName, enabled, requiresAuth, capabilities, type: "api", ...(unavailableReason ? { unavailableReason } : {}) };
}
