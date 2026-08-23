import type { RegisteredToolProvider } from "../tools/tool-provider-registry";
import type { StoredMcpServer } from "../mcp/types";

export interface CapabilityGapCandidate{requestedCapability:string;service:string|null;reason:string;blocking:boolean}
const BLOCKING:[RegExp,string,string][]=[
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
const LIVE=/(날씨|기상청|기상|기온|체감\s*온도|습도|강수|폭염|미세먼지|초미세|황사|비가\s*오|비(?:가|는|도)?\s*오|그칠|맑음|흐림)/i;
const LOCATION=/(내\s*위치|현재\s*위치|위치\s*정보|위치\s*기반|나의\s*위치)/i;
const REQUEST=/(해줘|해\s*줘|알려|확인|조회|언제|어때|좋은지|그칠)/i;
const SUPPORTED=/(gmail|메일|이메일|email|calendar|캘린더|일정|검색해|찾아줘|스케줄)/i;
const KNOWLEDGE=/(뭐야|뭔가요|설명|차이는|의미는|예제|번역해|요약해)/i;
const CHITCHAT=/^(안녕|하이|헬로|hello|hi|고마워|감사|ㅎㅎ|ㅋㅋ|응|아니야?|그래)[\s!.]*$/i;
const MISSING_RESPONSE=/(기능이 없|기능을 실행할 수 없|도구를 사용하지 않|도구가 없|API가 없|지원하지 않|직접 확인할 수 없|실시간.{0,20}(없|못)|확인할 수 있는 기능이 없|개발이 필요)/i;
const REASON="No registered Tool, Provider or MCP capability can perform this action. Runtime configuration alone cannot add the required integration.";

function hasCapability(service:string,providers:RegisteredToolProvider[],servers:Array<StoredMcpServer&{connection?:unknown}>,discoveredMcpTools:string[]){
  return providers.some(item=>item.service===service||item.providerId.toLowerCase().includes(service))
    ||servers.some(item=>item.id.toLowerCase().includes(service)||item.name.toLowerCase().includes(service)||item.providerId?.toLowerCase().includes(service))
    ||discoveredMcpTools.some(tool=>tool.toLowerCase().includes(service));
}

/** Logs unsupported mutations as blocking gaps, and other missing capabilities as non-blocking records. */
export function detectCapabilityGap(message:string,providers:RegisteredToolProvider[],servers:Array<StoredMcpServer&{connection?:unknown}>,discoveredMcpTools:string[]=[]):CapabilityGapCandidate|null{
  if(CHITCHAT.test(message.trim())||KNOWLEDGE.test(message)||SUPPORTED.test(message))return null;
  const blocking=BLOCKING.find(([pattern])=>pattern.test(message));
  if(blocking&&ACTION.test(message)){
    const[,service,capability]=blocking;
    if(hasCapability(service,providers,servers,discoveredMcpTools))return null;
    return{service,requestedCapability:capability,reason:REASON,blocking:true};
  }
  const live=LIVE.test(message),location=LOCATION.test(message),request=REQUEST.test(message)||ACTION.test(message);
  if((live||location)&&request){
    const service=live?"weather":"location";
    if(hasCapability(service,providers,servers,discoveredMcpTools))return null;
    return{service,requestedCapability:live?"위치 기반 날씨 조회":"위치 기반 조회",reason:REASON,blocking:false};
  }
  return null;
}

export function detectMissingCapabilityResponse(response:string){return MISSING_RESPONSE.test(response)}

export function inferRecordedGap(message:string):CapabilityGapCandidate{
  return detectCapabilityGap(message,[],[])??{requestedCapability:"현재 도구로 처리할 수 없는 요청",service:null,reason:"The assistant reported that no current tool or integration can fulfill this request.",blocking:false};
}
