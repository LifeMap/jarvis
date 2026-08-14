import type { Env } from "../env";
import { GoogleCalendarClient } from "./calendar/calendar-client";
import { GoogleGmailClient } from "./gmail/gmail-client";
import type { AccessTokenProvider, ToolProviderSet } from "./provider-types";
import type { ActiveToolProviders } from "./tool-provider-resolver";
import type { GenericMcpClient } from "../mcp/generic-mcp-client";
import type { McpRegistryService } from "../mcp/mcp-registry-service";
import { McpCalendarClient, McpGmailClient, McpSearchProvider } from "../mcp/mcp-tool-providers";
import {
  BraveSearchProvider,
  SerpApiSearchProvider,
  UnavailableSearchProvider,
} from "./search/search-provider";

const DEFAULT_PROVIDERS: ActiveToolProviders = {
  gmail: "gmail-api", calendar: "google-calendar-api", search: "brave-api",
};

export function createToolProviders(
  env: Env, googleAuth: AccessTokenProvider, active: ActiveToolProviders = DEFAULT_PROVIDERS,
  mcp?: { client: GenericMcpClient; registry: McpRegistryService },
): ToolProviderSet {
  const accessToken = () => googleAuth.getAccessToken();
  const gmail = new GoogleGmailClient(accessToken);
  const calendar = new GoogleCalendarClient(accessToken);
  const mcpGmail=mcp?.registry.serverForProvider(active.gmail);
  const mcpCalendar=mcp?.registry.serverForProvider(active.calendar);
  const mcpSearch=mcp?.registry.serverForProvider(active.search);
  const primarySearch = mcpSearch && mcp
    ? new McpSearchProvider(mcp.client,mcpSearch)
    : active.search === "brave-api" && env.SEARCH_API_KEY
    ? new BraveSearchProvider(env.SEARCH_API_KEY)
    : active.search === "serpapi" && env.SERP_API_KEY
      ? new SerpApiSearchProvider(env.SERP_API_KEY)
      : new UnavailableSearchProvider(`${active.search} Provider credential이 설정되지 않았습니다.`);
  const search = primarySearch;

  return {
    gmail: { identity: { service: "gmail", implementation: active.gmail }, client: mcpGmail&&mcp?new McpGmailClient(mcp.client,mcpGmail):gmail },
    calendar: { identity: { service: "calendar", implementation: active.calendar }, client: mcpCalendar&&mcp?new McpCalendarClient(mcp.client,mcpCalendar):calendar },
    search: {
      identity: {
        service: "search",
        implementation: mcpSearch ? active.search : (active.search === "brave-api" ? env.SEARCH_API_KEY : env.SERP_API_KEY) ? active.search : "unavailable",
      },
      provider: search,
    },
  };
}
