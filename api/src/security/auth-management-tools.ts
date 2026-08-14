import type { ToolDefinition } from "../tools/types";
import type { AuthStatusService } from "./auth-status-service";

export interface AuthManagementIntent{toolName:string;arguments:Record<string,unknown>}
export function createAuthManagementTools(service:AuthStatusService):ToolDefinition[]{return[
  tool("auth.list",async input=>input.required===true?service.requiringAuthorization():service.list(),summarize),
  tool("auth.get",async input=>service.get(String(input.target??"")),summarize),
  tool("auth.begin",async input=>service.begin(String(input.target??"")),result=>`인증 연결을 시작합니다. ${JSON.stringify(result)}`),
  tool("auth.disconnect",async input=>service.disconnect(String(input.target??"")),result=>`인증 연결을 해제했습니다. ${JSON.stringify(result)}`),
]}
export function parseAuthManagementIntent(message:string):AuthManagementIntent|null{const m=message.trim();const auth=/(인증|연결|auth)/i.test(m);if(!auth)return null;const target=/gmail|메일/i.test(m)?"gmail":/calendar|캘린더|일정/i.test(m)?"calendar":m.match(/mcp[.\s:-]*([a-z0-9_-]+)/i)?.[1]??"";const explicit=/(시작해|연결해|접속해|해제해|끊어|삭제해)/i.test(m);if(/(해제해|끊어)/i.test(m)&&target)return{toolName:"auth.disconnect",arguments:{target}};if(explicit&&/(시작해|연결해|접속해)/i.test(m)&&target)return{toolName:"auth.begin",arguments:{target}};if(/필요한|안\s*된|끊긴/i.test(m)&&/(알려|보여|확인)/i.test(m))return{toolName:"auth.list",arguments:{required:true}};if(/(상태|현재)/i.test(m)&&/(알려|보여|확인)/i.test(m))return target?{toolName:"auth.get",arguments:{target}}:{toolName:"auth.list",arguments:{}};return null;}
function tool(name:string,execute:ToolDefinition["execute"],summarize:ToolDefinition["summarize"]):ToolDefinition{return{name,description:"Secret 값을 노출하지 않고 인증 상태를 관리합니다.",inputSchema:{type:"object"},policy:"AUTO",requiresApproval:false,execute,summarize}}
function summarize(result:unknown){const items=Array.isArray(result)?result:[result];return items.length?`인증 상태\n${items.map(item=>{const x=item as {target?:string;authType?:string;status?:string;expiresAt?:string|null;reason?:string};return`- ${x.target}: ${x.authType} / ${x.status}${x.expiresAt?` (expires ${x.expiresAt})`:""}${x.reason?` — ${x.reason}`:""}`}).join("\n")}`:"조건에 맞는 인증 대상이 없습니다."}
