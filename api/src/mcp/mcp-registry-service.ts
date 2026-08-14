import type { Env } from "../env";
import type { RegisteredToolProvider } from "../tools/tool-provider-registry";
import { ToolError } from "../tools/types";
import type { GenericMcpClient } from "./generic-mcp-client";
import type { McpServerRepository } from "./mcp-server-repository";
import type { McpServerRegistration, StoredMcpServer } from "./types";
import { safeErrorMessage } from "../security/redaction";

const REQUIRED:Record<string,string[]>={gmail:["searchMessages","sendMessage","replyMessage"],calendar:["searchEvents","createEvent","updateEvent","deleteEvent"],search:["search"]};

export class McpRegistryService {
  constructor(private readonly repo:McpServerRepository,private readonly client:GenericMcpClient,private readonly env:Env,private readonly credentialResolver?:(reference:string)=>string|undefined){}
  list(){return this.repo.list().map(server=>({...server,connection:this.client.status(server.id)}));}
  get(id:string){const server=this.repo.get(id);return server?{...server,connection:this.client.status(id)}:undefined;}
  async register(input:McpServerRegistration){validate(input);const stored=this.repo.create(input);if(stored.enabled){try{return{server:stored,connection:await this.client.connect(stored)}}catch(error){return{server:stored,connection:{serverId:stored.id,state:"failed",connected:false,error:message(error)}}}}return{server:stored,connection:this.client.status(stored.id)};}
  async enable(id:string){const server=this.require(id);const result=await this.client.connect({...server,enabled:true});this.repo.setEnabled(id,true);return{server:this.repo.get(id)!,connection:result};}
  async disable(id:string){this.require(id);await this.client.disconnect(id);return this.repo.setEnabled(id,false)!;}
  async remove(id:string){this.require(id);await this.client.remove(id);return this.repo.delete(id);}
  async test(id:string){const server=this.require(id);const connection=await this.client.connect(server);const tools=connection.connected?await this.client.discover(id):[];return{connection,tools};}
  async tools(id:string){this.require(id);return this.client.discover(id);}
  async ensureEnabledConnections(){for(const server of this.repo.list().filter(item=>item.enabled)){if(!this.client.status(server.id).connected){try{await this.client.connect(server)}catch{/* Status and validation expose the failure; do not change active configuration. */}}}}
  providers():RegisteredToolProvider[]{return this.repo.list().filter(server=>server.service&&server.providerId).map(server=>{
    const status=this.client.status(server.id);const discovered=new Set(this.client.listTools(server.id).map(tool=>tool.toolName));const required=REQUIRED[server.service!]??[];const missing=required.filter(cap=>!server.capabilityMapping[cap]||!discovered.has(server.capabilityMapping[cap]!));
    const credentialReady=server.authType==="none"||server.authType==="oauth"||(Boolean(server.credentialReference)&&Boolean(this.credential(server.credentialReference!)));
    const enabled=server.enabled&&status.connected&&credentialReady&&missing.length===0;
    return{service:server.service!,providerId:server.providerId!,displayName:server.name,enabled,requiresAuth:server.authType!=="none",capabilities:Object.keys(server.capabilityMapping),type:"mcp" as const,mcpServerId:server.id,...(!enabled?{unavailableReason:!server.enabled?"MCP server is disabled":!status.connected?status.error??"MCP server is not connected":!credentialReady?"MCP credential is not configured":`Missing MCP capability mappings: ${missing.join(", ")}`}:{})};
  });}
  serverForProvider(providerId:string):StoredMcpServer|undefined{return this.repo.list().find(server=>server.providerId===providerId);}
  private require(id:string){const server=this.repo.get(id);if(!server)throw new ToolError("MCP server not found","등록되지 않은 MCP 서버입니다.");return server;}
  private credential(reference:string):string|undefined{return this.credentialResolver?.(reference)??(this.env as unknown as Record<string,unknown>)[reference] as string|undefined;}
}

function validate(input:McpServerRegistration){if(!/^[a-z0-9][a-z0-9_-]{0,63}$/i.test(input.id))throw new ToolError("Invalid MCP server id","MCP 서버 ID는 안전한 문자 1~64자로 입력해 주세요.");if(!input.name.trim()||input.name.length>100)throw new ToolError("Invalid MCP server name","MCP 서버 이름이 올바르지 않습니다.");let url:URL;try{url=new URL(input.endpoint)}catch{throw new ToolError("Invalid MCP endpoint","MCP endpoint URL이 올바르지 않습니다.")}if(url.username||url.password)throw new ToolError("Credentials in MCP URL are forbidden","MCP URL에 인증정보를 포함할 수 없습니다.");if(url.protocol!=="https:"&&!(url.protocol==="http:"&&(url.hostname==="localhost"||url.hostname==="127.0.0.1")))throw new ToolError("Insecure MCP endpoint","MCP endpoint는 HTTPS여야 합니다.");if((input.authType==="bearer"||input.authType==="api-key")&&!input.credentialReference)throw new ToolError("Missing credential reference","Secret 이름(credentialReference)이 필요합니다.");if(input.providerId&&!input.service)throw new ToolError("Missing MCP service","Provider에는 service가 필요합니다.");for(const [capability,tool] of Object.entries(input.capabilityMapping)){if(!capability||!tool)throw new ToolError("Invalid capability mapping","MCP capability mapping이 올바르지 않습니다.");}}
function message(error:unknown){return safeErrorMessage(error,"MCP connection failed")}
