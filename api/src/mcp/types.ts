import type { DynamicToolService } from "../tools/tool-provider-registry";

export type McpTransport = "streamable-http" | "sse" | "auto";
export type McpAuthType = "none" | "oauth" | "bearer" | "api-key";
export type McpCapabilityMapping = Record<string, string>;

export interface McpServerRegistration {
  id: string;
  name: string;
  endpoint: string;
  transport: McpTransport;
  enabled: boolean;
  authType: McpAuthType;
  credentialReference?: string;
  service?: DynamicToolService;
  providerId?: string;
  description?: string;
  capabilityMapping: McpCapabilityMapping;
}

export interface StoredMcpServer extends McpServerRegistration {
  createdAt: string;
  updatedAt: string;
}

export interface DiscoveredMcpTool {
  serverId: string;
  toolName: string;
  description?: string;
  inputSchema: Record<string, unknown>;
}

export interface McpConnectionStatus {
  serverId: string;
  state: string;
  connected: boolean;
  error?: string;
  authUrl?: string;
}
