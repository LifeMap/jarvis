import type { CalendarClient, CalendarEvent, CalendarWriteInput } from "../tools/calendar/calendar-client";
import type { GmailClient, GmailMessage, GmailMutationResult, GmailSendRequest } from "../tools/gmail/gmail-client";
import type { SearchProvider, SearchResult } from "../tools/search/search-provider";
import type { GenericMcpClient } from "./generic-mcp-client";
import type { StoredMcpServer } from "./types";

export class McpSearchProvider implements SearchProvider {
  constructor(private readonly client:GenericMcpClient,private readonly server:StoredMcpServer){}
  async search(query:string,count:number):Promise<SearchResult[]>{
    const raw=await this.call("search",{query,count});const data=extractData(raw);
    const items=Array.isArray(data)?data:Array.isArray((data as {results?:unknown[]})?.results)?(data as {results:unknown[]}).results:[];
    return items.slice(0,count).map((item,index)=>{const value=item as Record<string,unknown>;const url=string(value.url)??string(value.link)??this.server.endpoint;return{title:string(value.title)??`MCP result ${index+1}`,url,snippet:string(value.snippet)??string(value.description)??string(value.text)??"",source:string(value.source)??safeHost(url),provider:`mcp:${this.server.id}`}});
  }
  private call(capability:string,args:Record<string,unknown>){const tool=this.server.capabilityMapping[capability];if(!tool)throw new Error(`MCP capability ${capability} is not mapped`);return this.client.callTool(this.server.id,tool,args);}
}

export class McpGmailClient implements GmailClient {
  constructor(private readonly client:GenericMcpClient,private readonly server:StoredMcpServer){}
  async search(input:{query?:string;maxResults:number}):Promise<GmailMessage[]>{return arrayData(await this.call("searchMessages",input)).map(value=>value as unknown as GmailMessage);}
  async send(input:GmailSendRequest):Promise<GmailMutationResult>{const value=extractData(await this.call(input.threadId?"replyMessage":"sendMessage",{...input}));return value as GmailMutationResult;}
  private call(capability:string,args:Record<string,unknown>){const tool=this.server.capabilityMapping[capability];if(!tool)throw new Error(`MCP capability ${capability} is not mapped`);return this.client.callTool(this.server.id,tool,args);}
}

export class McpCalendarClient implements CalendarClient {
  constructor(private readonly client:GenericMcpClient,private readonly server:StoredMcpServer){}
  async listEvents(input:{timeMin:string;timeMax:string;timezone:string}):Promise<CalendarEvent[]>{return arrayData(await this.call("searchEvents",input)).map(value=>value as unknown as CalendarEvent);}
  async createEvent(input:CalendarWriteInput):Promise<CalendarEvent>{return extractData(await this.call("createEvent",{...input})) as CalendarEvent;}
  async updateEvent(eventId:string,input:CalendarWriteInput):Promise<CalendarEvent>{return extractData(await this.call("updateEvent",{eventId,...input})) as CalendarEvent;}
  async deleteEvent(eventId:string):Promise<{eventId:string;deleted:true}>{return extractData(await this.call("deleteEvent",{eventId})) as {eventId:string;deleted:true};}
  private call(capability:string,args:Record<string,unknown>){const tool=this.server.capabilityMapping[capability];if(!tool)throw new Error(`MCP capability ${capability} is not mapped`);return this.client.callTool(this.server.id,tool,args);}
}

function extractData(raw:unknown):unknown{const value=raw as {structuredContent?:unknown;content?:Array<{type?:string;text?:string}>};if(value?.structuredContent!==undefined)return value.structuredContent;const text=value?.content?.filter(x=>x.type==="text").map(x=>x.text??"").join("\n");if(text){try{return JSON.parse(text)}catch{return[{title:"MCP result",url:"",snippet:text,source:"MCP"}]}}return raw;}
function arrayData(raw:unknown):Record<string,unknown>[]{const data=extractData(raw);if(Array.isArray(data))return data as Record<string,unknown>[];for(const key of ["results","messages","events","items"]){const value=(data as Record<string,unknown>)?.[key];if(Array.isArray(value))return value as Record<string,unknown>[];}return[];}
function string(value:unknown):string|undefined{return typeof value==="string"&&value?value:undefined}
function safeHost(url:string):string{try{return new URL(url).hostname}catch{return"MCP"}}
