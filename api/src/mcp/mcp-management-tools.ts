import type { ToolContext, ToolDefinition } from "../tools/types";
import { ToolError } from "../tools/types";
import type { McpRegistryService } from "./mcp-registry-service";
import type { McpAuthType, McpServerRegistration, McpTransport } from "./types";

export type McpManagementIntent={toolName:string;arguments:Record<string,unknown>};
export function createMcpManagementTools(service:McpRegistryService):ToolDefinition[]{return[
  tool("mcp.list_servers","List registered MCP servers",async()=>service.list(),result=>JSON.stringify(result,null,2)),
  tool("mcp.get_server","Get one MCP server",async input=>service.get(required(input.id,"id"))??missing(),result=>JSON.stringify(result,null,2)),
  tool("mcp.register_server","Register an explicitly requested MCP server",async input=>service.register(parseRegistration(input)),result=>`MCP 서버를 등록했습니다.\n${JSON.stringify(result,null,2)}`),
  tool("mcp.remove_server","Remove an MCP server",async input=>service.remove(required(input.id,"id")),()=>"MCP 서버를 제거했습니다."),
  tool("mcp.enable_server","Enable and connect an MCP server",async input=>service.enable(required(input.id,"id")),result=>`MCP 서버를 활성화했습니다.\n${JSON.stringify(result,null,2)}`),
  tool("mcp.disable_server","Disable and disconnect an MCP server",async input=>service.disable(required(input.id,"id")),()=>"MCP 서버 연결을 비활성화했습니다."),
  tool("mcp.test_connection","Test MCP connection and discover tools",async input=>service.test(required(input.id,"id")),result=>JSON.stringify(result,null,2)),
  tool("mcp.list_tools","Discover tools from one MCP server",async input=>service.tools(required(input.id,"id")),result=>JSON.stringify(result,null,2)),
];}

export function parseMcpManagementIntent(message:string):McpManagementIntent|null{const text=message.trim();if(!/(mcp\s*서버|mcp\s*server|등록된\s*mcp|mcp\s*(tool|도구))/i.test(text))return null;const id=extract(text,/\b(?:id|서버)\s*[:=]?\s*([a-z0-9][a-z0-9_-]{0,63})/i);if(/(목록|리스트|등록된|list).*(도구|tool)/i.test(text))return{toolName:"mcp.list_tools",arguments:{id:id??""}};if(/(연결).*(테스트|시험)|test.*connection/i.test(text))return{toolName:"mcp.test_connection",arguments:{id:id??""}};if(/(비활성|연결.*끊|disable|disconnect)/i.test(text))return{toolName:"mcp.disable_server",arguments:{id:id??""}};if(/(활성|연결해|enable|connect)/i.test(text)&&!/(추가|등록|register)/i.test(text))return{toolName:"mcp.enable_server",arguments:{id:id??""}};if(/(삭제|제거|remove|delete)/i.test(text))return{toolName:"mcp.remove_server",arguments:{id:id??""}};if(/(추가|등록|register)/i.test(text)){const endpoint=extract(text,/(https?:\/\/[^\s]+)/i);return{toolName:"mcp.register_server",arguments:{id:id??"",name:id??"MCP server",endpoint:endpoint?.replace(/[),.]+$/,""),transport:"streamable-http",authType:"none",enabled:true,capabilityMapping:{}}};}if(id)return{toolName:"mcp.get_server",arguments:{id}};return{toolName:"mcp.list_servers",arguments:{}};}

function tool(name:string,description:string,execute:(input:Record<string,unknown>,context:ToolContext)=>Promise<unknown>,summarize:(result:any)=>string):ToolDefinition{return{name,description,inputSchema:{type:"object",additionalProperties:true},policy:"AUTO",requiresApproval:false,execute,summarize};}
function required(value:unknown,name:string):string{if(typeof value!=="string"||!value.trim())throw new ToolError(`Missing ${name}`,`${name} 값이 필요합니다.`);return value.trim();}
function missing():never{throw new ToolError("MCP server not found","등록되지 않은 MCP 서버입니다.")}
function parseRegistration(input:Record<string,unknown>):McpServerRegistration{return{id:required(input.id,"id"),name:required(input.name,"name"),endpoint:required(input.endpoint,"endpoint"),transport:(input.transport??"streamable-http") as McpTransport,enabled:input.enabled!==false,authType:(input.authType??"none") as McpAuthType,...(typeof input.credentialReference==="string"?{credentialReference:input.credentialReference}:{}),...(input.service==="gmail"||input.service==="calendar"||input.service==="search"?{service:input.service}:{}),...(typeof input.providerId==="string"?{providerId:input.providerId}:{}),...(typeof input.description==="string"?{description:input.description}:{}),capabilityMapping:isRecord(input.capabilityMapping)?Object.fromEntries(Object.entries(input.capabilityMapping).filter((x):x is [string,string]=>typeof x[1]==="string")): {}};}
function isRecord(value:unknown):value is Record<string,unknown>{return Boolean(value)&&typeof value==="object"&&!Array.isArray(value)}
function extract(text:string,pattern:RegExp):string|undefined{return text.match(pattern)?.[1]}
