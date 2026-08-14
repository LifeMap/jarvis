import type { Env } from "../env";
import type { McpRegistryService } from "../mcp/mcp-registry-service";
import type { GoogleOAuthService } from "../oauth/google-oauth-service";
import type { CredentialStatus, CredentialStore } from "./credential-store";
import { redactText } from "./redaction";

export interface AuthStatus { target:string;authType:"binding"|"api-key"|"oauth"|"bearer"|"none";status:CredentialStatus|"configured";credentialRef?:string;expiresAt?:string|null;scopes?:string[];reason?:string }

export class AuthStatusService {
  constructor(private readonly env:Env,private readonly credentials:CredentialStore,private readonly google:GoogleOAuthService,private readonly mcp:McpRegistryService){}
  list():AuthStatus[]{
    const google=this.googleStatus();
    return[
      infrastructure("workers-ai","binding",Boolean(this.env.AI),"binding:AI"),
      infrastructure("openai","api-key",Boolean(this.env.OPENAI_API_KEY),"env:OPENAI_API_KEY"),
      infrastructure("brave-api","api-key",Boolean(this.env.SEARCH_API_KEY),"env:SEARCH_API_KEY"),
      infrastructure("serpapi","api-key",Boolean(this.env.SERP_API_KEY),"env:SERP_API_KEY"),
      {target:"gmail",...google},{target:"calendar",...google},
      ...this.mcp.list().map(server=>this.mcpStatus(server)),
    ];
  }
  get(target:string){const normalized=target.toLowerCase();return this.list().filter(item=>item.target.toLowerCase().includes(normalized));}
  requiringAuthorization(){return this.list().filter(item=>item.status==="authorization-required"||item.status==="expired"||item.status==="refresh-failed"||item.status==="revoked"||item.status==="error"||item.status==="not-configured");}
  begin(target:string){if(/gmail|calendar|google/i.test(target))return{target:"google",status:"authorization-required",authorizationEndpoint:"/api/oauth/google/authorize"};const server=this.mcp.list().find(item=>item.id===target||item.providerId===target);if(server?.authType==="oauth")return{target:server.id,status:server.connection.authUrl?"authorization-required":"registered",...(server.connection.authUrl?{authorizationUrl:server.connection.authUrl}:{})};return{target,status:"not-configured",message:"이 대상에는 지원되는 대화형 인증 연결 방식이 없습니다."};}
  disconnect(target:string){if(/gmail|calendar|google/i.test(target))return{target:"google",disconnected:this.google.disconnect(),status:"authorization-required"};throw new Error("MCP 연결 해제는 MCP 서버 비활성화/삭제 명령을 사용해 주세요.");}
  private googleStatus():Omit<AuthStatus,"target">{const status=this.google.status();const metadata=this.credentials.getCredentialMetadata("google-oauth-main");return{authType:"oauth",status:metadata?.status??status.status as CredentialStatus,credentialRef:"google-oauth-main",expiresAt:status.expiresAt,scopes:status.scopes,...(!status.connected?{reason:"Google 계정 연결이 필요합니다."}:{})};}
  private mcpStatus(server:ReturnType<McpRegistryService["list"]>[number]):AuthStatus{if(server.authType==="none")return{target:`mcp.${server.id}`,authType:"none",status:"configured"};if(server.authType==="oauth")return{target:`mcp.${server.id}`,authType:"oauth",status:server.connection.connected?"valid":"authorization-required",...(server.credentialReference?{credentialRef:server.credentialReference}:{}),...(server.connection.error?{reason:redactText(server.connection.error)}:{})};const metadata=server.credentialReference?this.credentials.getCredentialMetadata(server.credentialReference):undefined;const envReady=server.credentialReference&&Boolean((this.env as unknown as Record<string,unknown>)[server.credentialReference]);return{target:`mcp.${server.id}`,authType:server.authType,status:metadata?.status??(envReady?"configured":"not-configured"),...(server.credentialReference?{credentialRef:server.credentialReference}:{}),...(!metadata&&!envReady?{reason:"Credential이 설정되지 않았습니다."}:{})};}
}
function infrastructure(target:string,authType:"binding"|"api-key",configured:boolean,credentialRef:string):AuthStatus{return{target,authType,status:configured?"configured":"not-configured",credentialRef,...(!configured?{reason:`${credentialRef}가 설정되지 않았습니다.`}:{})}}
