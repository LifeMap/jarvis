import type { RegisteredToolProvider } from "../tools/tool-provider-registry";
import type { StoredMcpServer } from "../mcp/types";

export interface CapabilityGapCandidate{requestedCapability:string;service:string|null;reason:string}
const UNSUPPORTED:[RegExp,string,string][]=[
  [/\bnotion\b|노션/i,"notion","Notion 페이지/데이터베이스 작성"],
  [/\bslack\b|슬랙/i,"slack","Slack 메시지 전송"],
  [/\bdiscord\b|디스코드/i,"discord","Discord 메시지 전송"],
  [/\bgithub\b|깃허브/i,"github","GitHub 저장소 변경"],
  [/\bdropbox\b|드롭박스/i,"dropbox","Dropbox 파일 관리"],
  [/\bgoogle\s*drive\b|구글\s*드라이브/i,"google-drive","Google Drive 파일 관리"],
  [/pdf.{0,12}(서명|sign)|(?:서명|sign).{0,12}pdf/i,"pdf","PDF 전자서명"],
  [/\btrello\b|트렐로/i,"trello","Trello 카드 관리"],
];
const ACTION=/(등록|저장|추가|작성|생성|수정|변경|삭제|전송|보내|업로드|서명|게시|create|add|write|update|delete|send|upload|sign|post)/i;

/** Conservative catalog check: only explicit external mutations with no registered capability are logged. */
export function detectCapabilityGap(message:string,providers:RegisteredToolProvider[],servers:Array<StoredMcpServer&{connection?:unknown}>,discoveredMcpTools:string[]=[]):CapabilityGapCandidate|null{
  if(!ACTION.test(message))return null;
  const match=UNSUPPORTED.find(([pattern])=>pattern.test(message));if(!match)return null;
  const[,service,capability]=match;
  const providerExists=providers.some(item=>item.service===service||item.providerId.toLowerCase().includes(service));
  const mcpExists=servers.some(item=>item.id.toLowerCase().includes(service)||item.name.toLowerCase().includes(service)||item.providerId?.toLowerCase().includes(service))||discoveredMcpTools.some(tool=>tool.toLowerCase().includes(service));
  if(providerExists||mcpExists)return null;
  return{service,requestedCapability:capability,reason:"No registered Tool, Provider or MCP capability can perform this action. Runtime configuration alone cannot add the required integration."};
}
