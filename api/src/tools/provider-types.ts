import type { CalendarClient } from "./calendar/calendar-client";
import type { GmailClient } from "./gmail/gmail-client";
import type { SearchProvider } from "./search/search-provider";

export type ToolProviderService = "gmail" | "calendar" | "search" | "scheduler" | "mcp";
export type ToolProviderImplementation = string;
/* Built-in identities are documented here; runtime MCP providers use their configured id. */
export type BuiltInToolProviderImplementation =
  | "gmail-api"
  | "google-calendar-api"
  | "brave-api"
  | "serpapi"
  | "cloudflare-agents"
  | "unavailable";

export interface ToolProviderIdentity {
  service: ToolProviderService;
  implementation: ToolProviderImplementation;
  fallbackImplementation?: ToolProviderImplementation;
}

export interface ToolProviderSet {
  gmail: { identity: ToolProviderIdentity; client: GmailClient };
  calendar: { identity: ToolProviderIdentity; client: CalendarClient };
  search: { identity: ToolProviderIdentity; provider: SearchProvider };
}

export interface AccessTokenProvider {
  getAccessToken(): Promise<string>;
}
