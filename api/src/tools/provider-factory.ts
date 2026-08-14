import type { Env } from "../env";
import { GoogleCalendarClient } from "./calendar/calendar-client";
import { GoogleGmailClient } from "./gmail/gmail-client";
import type { AccessTokenProvider, ToolProviderSet } from "./provider-types";
import type { ActiveToolProviders } from "./tool-provider-resolver";
import {
  BraveSearchProvider,
  RateLimitFallbackSearchProvider,
  SerpApiSearchProvider,
  UnavailableSearchProvider,
} from "./search/search-provider";

const DEFAULT_PROVIDERS: ActiveToolProviders = {
  gmail: "gmail-api", calendar: "google-calendar-api", search: "brave-api",
};

export function createToolProviders(
  env: Env, googleAuth: AccessTokenProvider, active: ActiveToolProviders = DEFAULT_PROVIDERS,
): ToolProviderSet {
  const accessToken = () => googleAuth.getAccessToken();
  const gmail = new GoogleGmailClient(accessToken);
  const calendar = new GoogleCalendarClient(accessToken);
  const primarySearch = active.search === "brave-api" && env.SEARCH_API_KEY
    ? new BraveSearchProvider(env.SEARCH_API_KEY)
    : active.search === "serpapi" && env.SERP_API_KEY
      ? new SerpApiSearchProvider(env.SERP_API_KEY)
      : new UnavailableSearchProvider(`${active.search} Provider credential이 설정되지 않았습니다.`);
  const hasSerpApiFallback = env.SEARCH_FALLBACK_PROVIDER === "serpapi" && Boolean(env.SERP_API_KEY);
  const search = active.search === "brave-api" && hasSerpApiFallback
    ? new RateLimitFallbackSearchProvider(primarySearch, new SerpApiSearchProvider(env.SERP_API_KEY!))
    : primarySearch;

  return {
    gmail: { identity: { service: "gmail", implementation: active.gmail }, client: gmail },
    calendar: { identity: { service: "calendar", implementation: active.calendar }, client: calendar },
    search: {
      identity: {
        service: "search",
        implementation: (active.search === "brave-api" ? env.SEARCH_API_KEY : env.SERP_API_KEY) ? active.search : "unavailable",
        ...(active.search === "brave-api" && hasSerpApiFallback ? { fallbackImplementation: "serpapi" as const } : {}),
      },
      provider: search,
    },
  };
}
