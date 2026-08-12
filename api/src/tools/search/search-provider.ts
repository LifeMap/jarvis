export interface SearchResult { title: string; url: string; snippet: string; source: string }
export interface SearchProvider { search(query: string, count: number): Promise<SearchResult[]> }

export class UnavailableSearchProvider implements SearchProvider {
  constructor(private readonly reason: string) {}
  async search(): Promise<SearchResult[]> { throw new Error(this.reason); }
}

export class BraveSearchProvider implements SearchProvider {
  constructor(private readonly apiKey: string, private readonly fetcher: typeof fetch = fetch) {}
  async search(query: string, count: number): Promise<SearchResult[]> {
    const url = new URL("https://api.search.brave.com/res/v1/web/search");
    url.search = new URLSearchParams({ q: query.slice(0, 400), count: String(Math.min(Math.max(count, 1), 10)), safesearch: "moderate" }).toString();
    const response = await this.fetcher(url, { headers: { accept: "application/json", "x-subscription-token": this.apiKey } });
    if (!response.ok) throw new Error(`Brave Search API 요청 실패 (${response.status})`);
    const payload = await response.json() as { web?: { results?: Array<{ title?: string; url?: string; description?: string; profile?: { long_name?: string } }> } };
    return (payload.web?.results ?? []).filter((item) => item.title && item.url).map((item) => ({
      title: item.title!, url: item.url!, snippet: item.description ?? "", source: item.profile?.long_name ?? new URL(item.url!).hostname,
    }));
  }
}
