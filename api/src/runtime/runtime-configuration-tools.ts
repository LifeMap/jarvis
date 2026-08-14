import type { ModelProviderId } from "../llm/types";
import type { ToolContext,ToolDefinition } from "../tools/types";
import { ToolError } from "../tools/types";
import type { DynamicToolService } from "../tools/tool-provider-registry";
import type { RuntimeChange,RuntimeConfigurationManager } from "./runtime-configuration-manager";

export type RuntimeConfigurationIntent={toolName:string;arguments:Record<string,unknown>};
export function createRuntimeConfigurationTools(manager:RuntimeConfigurationManager):ToolDefinition[]{return[
  tool("runtime.get_configuration","Get a secret-free snapshot of all runtime configuration",async()=>manager.getConfiguration(),summarizeConfiguration),
  tool("runtime.apply_changes","Validate and atomically apply explicit runtime configuration changes",async input=>manager.applyChange(parseChanges(input.changes)),summarizeChanges),
  tool("runtime.reset_all","Reset model and Tool Provider active selections without deleting MCP integrations",async()=>manager.resetAll(),summarizeChanges),
  tool("runtime.list_history","List recent secret-free runtime configuration changes",async(input,context)=>filterHistory(manager.getHistory(typeof input.limit==="number"?input.limit:50),input,context.timezone),summarizeHistory),
];}

export function parseRuntimeConfigurationIntent(message:string):RuntimeConfigurationIntent|null{
  const text=message.trim();
  if(/(최근|오늘|언제|내역|history).*(설정|모델|provider|프로바이더|mcp)|(설정).*(변경).*(내역|기록)/i.test(text))return{toolName:"runtime.list_history",arguments:{limit:50,...(/모델/i.test(text)?{target:"model"}:{}),...(/gmail|지메일/i.test(text)?{target:"tools.gmail"}:{}),...(/오늘/i.test(text)?{today:true}:{})}};
  if(/(현재|지금).*(jarvis|자비스).*(설정|구성)|(jarvis|자비스).*(설정|구성).*(알려|보여|확인)|전체\s*(runtime|런타임)?\s*(설정|구성)/i.test(text))return{toolName:"runtime.get_configuration",arguments:{}};
  const explicitAction=/(바꿔|변경|전환|설정|되돌|돌아가|복귀|reset|사용해|사용할게|써|유지해|switch|change|set)/i.test(text);
  if(!explicitAction)return null;
  if(/(jarvis|자비스).*(설정|구성).*(기본|초기)|(전체).*(설정|구성).*(기본|초기)/i.test(text))return{toolName:"runtime.reset_all",arguments:{}};
  const changes:RuntimeChange[]=[];
  const model=readModelChange(text);if(model)changes.push(model);
  for(const service of ["gmail","calendar","search"] as const){const change=readToolChange(text,service);if(change)changes.push(change);}
  if(changes.length>1)return{toolName:"runtime.apply_changes",arguments:{changes}};
  const only=changes[0];
  return only?.kind==="tool.set"&&(only.providerId==="mcp"||only.providerId==="api")?{toolName:"runtime.apply_changes",arguments:{changes}}:null;
}

function readModelChange(text:string):RuntimeChange|null{if(!/(모델|model|workers\s*-?\s*ai|open\s*-?\s*ai|오픈에이아이|워커스)/i.test(text))return null;if(/(모델|model)[^,.]*(기본|default)[^,.]*(되돌|돌아|복귀|reset)|(기본|default)[^,.]*(모델|model)[^,.]*(되돌|돌아|복귀|reset)/i.test(text))return{kind:"model.reset"};const provider:modelProviderResult=/open\s*-?\s*ai|오픈에이아이/i.test(text)?"openai":/workers\s*-?\s*ai|워커스|qwen/i.test(text)?"workers-ai":null;if(!provider)return null;const known=text.match(/@cf\/[A-Za-z0-9._/-]+|gpt-[A-Za-z0-9._-]+/i)?.[0];return{kind:"model.set",provider,...(known?{model:known}:{})};}
type modelProviderResult=ModelProviderId|null;
function readToolChange(text:string,service:DynamicToolService):RuntimeChange|null{const aliases=service==="gmail"?/gmail|지메일|메일/i:service==="calendar"?/calendar|캘린더|일정/i:/search|검색/i;if(!aliases.test(text))return null;const segment=serviceSegment(text,aliases);if(!/(바꿔|변경|전환|설정|되돌|돌아가|복귀|reset|사용해|써|유지해|switch|change|set)/i.test(segment))return null;if(/(기본|default).*(되돌|돌아|복귀|reset)|(되돌|돌아|복귀|reset).*(기본|default)/i.test(segment))return{kind:"tool.reset",service};const explicit=segment.match(/[a-z0-9][a-z0-9_-]{1,63}-(?:api|mcp)\b|\bserpapi\b/i)?.[0];const requested=explicit?.toLowerCase()??(/mcp/i.test(segment)?"mcp":/(api|기존)/i.test(segment)?"api":null);return requested?{kind:"tool.set",service,providerId:requested}:null;}
function serviceSegment(text:string,alias:RegExp){const index=text.search(alias);if(index<0)return"";const rest=text.slice(index);return rest.split(/(?:그리고|하고|이며|,|\band\b)/i)[0]??rest;}
function parseChanges(value:unknown):RuntimeChange[]{if(!Array.isArray(value))throw new ToolError("Invalid change plan","Runtime configuration 변경 계획이 올바르지 않습니다.");return value as RuntimeChange[];}
function tool(name:string,description:string,execute:(input:Record<string,unknown>,context:ToolContext)=>Promise<unknown>,summarize:(result:any)=>string):ToolDefinition{return{name,description,inputSchema:{type:"object",additionalProperties:true},policy:"AUTO",requiresApproval:false,execute,summarize};}
function summarizeConfiguration(result:ReturnType<RuntimeConfigurationManager["getConfiguration"]>){const tools=Object.entries(result.tools).map(([name,value])=>`${name}: ${value.active.providerId} (default: ${value.default.providerId})`).join("\n");const servers=result.mcp.servers.length?result.mcp.servers.map(server=>`- ${server.id}: ${server.connection.state}`).join("\n"):"- 등록된 서버 없음";return`현재 Jarvis Runtime 설정\n\nModel\n- Provider: ${result.model.active.provider}\n- Model: ${result.model.active.model}\n- Default: ${result.model.active.isDefault?"Yes":"No"}\n\nTool Providers\n${tools}\n\nMCP\n${servers}`;}
function summarizeChanges(result:ReturnType<RuntimeConfigurationManager["applyChange"]>){return`변경 완료\n\n${result.plan.map(item=>`${item.target}: ${short(item.previousValue)} → ${short(item.newValue)}`).join("\n")}`;}
function filterHistory(entries:ReturnType<RuntimeConfigurationManager["getHistory"]>,input:Record<string,unknown>,timezone:string){const today=new Intl.DateTimeFormat("en-CA",{timeZone:timezone,year:"numeric",month:"2-digit",day:"2-digit"}).format(new Date());return entries.filter(item=>(typeof input.target!=="string"||item.target===input.target)&&(!input.today||new Intl.DateTimeFormat("en-CA",{timeZone:timezone,year:"numeric",month:"2-digit",day:"2-digit"}).format(new Date(item.timestamp))===today));}
function summarizeHistory(entries:ReturnType<RuntimeConfigurationManager["getHistory"]>){return entries.length?`최근 Runtime 설정 변경 내역\n${entries.map(item=>`- ${item.timestamp} ${item.target}: ${short(item.previousValue)} → ${short(item.newValue)} (${item.source})`).join("\n")}`:"조건에 맞는 Runtime 설정 변경 내역이 없습니다.";}
function short(value:unknown){if(value&&typeof value==="object"){const item=value as Record<string,unknown>;return String(item.model??item.providerId??JSON.stringify(value));}return String(value);}
