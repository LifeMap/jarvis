import type { DiscoveredMcpTool, McpConnectionStatus, StoredMcpServer } from "./types";

interface McpHost {
  addMcpServer(name:string,url:string,options:Record<string,unknown>):Promise<{id:string;state:string;authUrl?:string}>;
  removeMcpServer(id:string):Promise<void>;
  getMcpServers(): {servers:Record<string,{state:string;error:string|null;auth_url:string|null}>;tools:Array<{serverId:string;name:string;description?:string;inputSchema?:Record<string,unknown>}>};
  mcp:{closeConnection(id:string):Promise<void>;discoverIfConnected(id:string):Promise<{success:boolean;state:string;error?:string}>;callTool(input:{serverId:string;name:string;arguments:Record<string,unknown>}):Promise<unknown>};
}

export class GenericMcpClient {
  constructor(private readonly host:McpHost,private readonly credentialResolver:(reference:string)=>string|undefined=()=>undefined){}
  async connect(server:StoredMcpServer):Promise<McpConnectionStatus>{
    const headers=this.authHeaders(server);
    const result=await this.host.addMcpServer(server.name,server.endpoint,{id:server.id,transport:{type:server.transport,...(headers?{headers}:{})}});
    return{serverId:server.id,state:result.state,connected:result.state==="ready",...(result.authUrl?{authUrl:result.authUrl}:{})};
  }
  async disconnect(serverId:string):Promise<void>{await this.host.mcp.closeConnection(serverId);}
  async remove(serverId:string):Promise<void>{await this.host.removeMcpServer(serverId);}
  status(serverId:string):McpConnectionStatus{const server=this.host.getMcpServers().servers[serverId];return server?{serverId,state:server.state,connected:server.state==="ready",...(server.error?{error:server.error}:{}),...(server.auth_url?{authUrl:server.auth_url}:{})}:{serverId,state:"disconnected",connected:false};}
  async discover(serverId:string):Promise<DiscoveredMcpTool[]>{const result=await this.host.mcp.discoverIfConnected(serverId);if(!result.success)throw new Error(result.error??`MCP discovery failed (${result.state})`);return this.listTools(serverId);}
  listTools(serverId:string):DiscoveredMcpTool[]{return this.host.getMcpServers().tools.filter(tool=>tool.serverId===serverId).map(tool=>({serverId,toolName:tool.name,...(tool.description?{description:tool.description}:{}),inputSchema:tool.inputSchema??{type:"object",properties:{}}}));}
  callTool(serverId:string,toolName:string,args:Record<string,unknown>):Promise<unknown>{return this.host.mcp.callTool({serverId,name:toolName,arguments:args});}
  private authHeaders(server:StoredMcpServer):Record<string,string>|undefined{
    if(server.authType==="none"||server.authType==="oauth")return undefined;
    if(!server.credentialReference)throw new Error("MCP credentialReference is required");
    const value=this.credentialResolver(server.credentialReference);if(!value)throw new Error(`MCP credential ${server.credentialReference} is not configured`);
    return server.authType==="bearer"?{authorization:`Bearer ${value}`}:{"x-api-key":value};
  }
}
