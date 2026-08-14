export interface SearchResult { title: string; url: string; snippet: string; source: string; provider?: string }
export interface SearchProvider { search(query: string, count: number): Promise<SearchResult[]> }

export class SearchProviderError extends Error {
  constructor(readonly provider: "brave"|"serpapi", readonly status: number, message: string, options?:ErrorOptions){super(message,options);this.name="SearchProviderError"}
}

export class UnavailableSearchProvider implements SearchProvider {
  constructor(private readonly reason: string) {}
  async search(): Promise<SearchResult[]> { throw new Error(this.reason); }
}

export class BraveSearchProvider implements SearchProvider {
  constructor(private readonly apiKey: string, private readonly fetcher: typeof fetch = (input, init) => fetch(input, init)) {}
  async search(query: string, count: number): Promise<SearchResult[]> {
    const url = new URL("https://api.search.brave.com/res/v1/web/search");
    url.search = new URLSearchParams({ q: query.slice(0, 400), count: String(Math.min(Math.max(count, 1), 10)), safesearch: "moderate" }).toString();
    const response = await this.fetcher(url, { headers: { accept: "application/json", "x-subscription-token": this.apiKey } });
    if (!response.ok) throw new SearchProviderError("brave",response.status,`Brave Search API 요청 실패 (${response.status})`);
    const payload = await response.json() as { web?: { results?: Array<{ title?: string; url?: string; description?: string; profile?: { long_name?: string } }> } };
    return (payload.web?.results ?? []).filter((item) => item.title && item.url).map((item) => ({
      title: item.title!, url: item.url!, snippet: item.description ?? "", source: item.profile?.long_name ?? new URL(item.url!).hostname, provider:"brave",
    }));
  }
}

export class SerpApiSearchProvider implements SearchProvider {
  constructor(private readonly apiKey:string,private readonly fetcher:typeof fetch=(input,init)=>fetch(input,init)){}
  async search(query:string,count:number):Promise<SearchResult[]>{
    const url=new URL("https://serpapi.com/search.json");
    url.search=new URLSearchParams({engine:"google",q:query.slice(0,400),num:String(Math.min(Math.max(count,1),10)),api_key:this.apiKey}).toString();
    const response=await this.fetcher(url,{headers:{accept:"application/json"}});
    const payload=await response.json() as {error?:string;organic_results?:Array<{title?:string;link?:string;snippet?:string;source?:string;displayed_link?:string}>};
    if(!response.ok||payload.error)throw new SearchProviderError("serpapi",response.status,payload.error??`SerpApi 요청 실패 (${response.status})`);
    return(payload.organic_results??[]).filter(item=>item.title&&item.link).map(item=>({title:item.title!,url:item.link!,snippet:item.snippet??"",source:item.source??item.displayed_link??new URL(item.link!).hostname,provider:"serpapi"}));
  }
}

export class RateLimitFallbackSearchProvider implements SearchProvider {
  constructor(private readonly primary:SearchProvider,private readonly fallback:SearchProvider,private readonly wait:(ms:number)=>Promise<void>=(ms)=>new Promise(resolve=>setTimeout(resolve,ms))){}
  async search(query:string,count:number):Promise<SearchResult[]>{
    try{return await this.primary.search(query,count)}catch(error){if(!isRateLimit(error))throw error}
    await this.wait(1_000);
    try{return await this.primary.search(query,count)}catch(error){if(!isRateLimit(error))throw error}
    return this.fallback.search(query,count);
  }
}

function isRateLimit(error:unknown):error is SearchProviderError{return error instanceof SearchProviderError&&error.status===429}
