import type { ToolContext, ToolDefinition } from "../tools/types";
import type { ToolProviderIdentity } from "../tools/provider-types";
import type { GenericMcpClient } from "./generic-mcp-client";
import type { DiscoveredMcpTool } from "./types";

export interface AdaptedMcpTool { tool:ToolDefinition; identity:ToolProviderIdentity }
export function adaptMcpTools(client:GenericMcpClient,tools:DiscoveredMcpTool[]):AdaptedMcpTool[]{return tools.map(discovered=>({
  tool:{
    name:`mcp__${safe(discovered.serverId)}__${safe(discovered.toolName)}`,
    description:`MCP (${discovered.serverId}): ${discovered.description??discovered.toolName}`,
    inputSchema:discovered.inputSchema,
    policy:"APPROVAL_REQUIRED",
    requiresApproval:true,
    execute:(input:Record<string,unknown>,_context:ToolContext)=>client.callTool(discovered.serverId,discovered.toolName,input),
    summarize:()=>`MCP Tool ${discovered.toolName} 실행이 완료되었습니다.`,
  },
  identity:{service:"mcp",implementation:`mcp:${discovered.serverId}`},
}));}
function safe(value:string){return value.replace(/[^a-zA-Z0-9_-]/g,"_").slice(0,64)}
