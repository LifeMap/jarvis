import type { Env } from "../env";
import { GoogleCalendarClient } from "./calendar/calendar-client";
import { GoogleGmailClient } from "./gmail/gmail-client";
import type { AccessTokenProvider, ToolProviderSet } from "./provider-types";
import {
  BraveSearchProvider,
  RateLimitFallbackSearchProvider,
  SerpApiSearchProvider,
  UnavailableSearchProvider,
} from "./search/search-provider";

export function createToolProviders(env: Env, googleAuth: AccessTokenProvider): ToolProviderSet {
  const accessToken = () => googleAuth.getAccessToken();
  const gmail = new GoogleGmailClient(accessToken);
  const calendar = new GoogleCalendarClient(accessToken);
  const primarySearch = env.SEARCH_PROVIDER === "brave" && env.SEARCH_API_KEY
    ? new BraveSearchProvider(env.SEARCH_API_KEY)
    : new UnavailableSearchProvider("SEARCH_PROVIDER 또는 SEARCH_API_KEY가 설정되지 않았습니다.");
  const hasSerpApiFallback = env.SEARCH_FALLBACK_PROVIDER === "serpapi" && Boolean(env.SERP_API_KEY);
  const search = hasSerpApiFallback
    ? new RateLimitFallbackSearchProvider(primarySearch, new SerpApiSearchProvider(env.SERP_API_KEY!))
    : primarySearch;

  return {
    gmail: { identity: { service: "gmail", implementation: "google-api" }, client: gmail },
    calendar: { identity: { service: "calendar", implementation: "google-api" }, client: calendar },
    search: {
      identity: {
        service: "search",
        implementation: env.SEARCH_PROVIDER === "brave" && env.SEARCH_API_KEY ? "brave-api" : "unavailable",
        ...(hasSerpApiFallback ? { fallbackImplementation: "serpapi" as const } : {}),
      },
      provider: search,
    },
  };
}
