import type{ModelConfigurationService}from"../llm/model-configuration-service";
import type{McpRegistryService}from"../mcp/mcp-registry-service";
import type{ToolProviderConfigurationService}from"../tools/tool-provider-configuration-service";
import type{ProviderHealthRepository,ProviderHealthStatus}from"./provider-health";

export class ProviderHealthService{
  constructor(private readonly repo:ProviderHealthRepository,private readonly models:ModelConfigurationService,private readonly tools:ToolProviderConfigurationService,private readonly mcp:McpRegistryService){}
  checkAll():ProviderHealthStatus[]{const result:ProviderHealthStatus[]=[];for(const model of this.models.listAvailable())result.push(this.repo.set(`model.${model.provider}.${model.model}`,model.enabled?"healthy":"unavailable",model.unavailableReason?{reason:model.unavailableReason}:{}));for(const provider of this.tools.list())result.push(this.repo.set(`tools.${provider.service}.${provider.providerId}`,provider.enabled?"healthy":"unavailable",provider.unavailableReason?{reason:provider.unavailableReason}:{}));for(const server of this.mcp.list()){const status=server.enabled&&server.connection.connected?"healthy":server.connection.state==="authenticating"?"degraded":server.enabled?"unavailable":"unknown";result.push(this.repo.set(`mcp.${server.id}`,status,server.connection.error?{reason:server.connection.error}:{}));}return result;}
  check(target?:string){const all=this.checkAll();return target?all.filter(item=>item.target.toLowerCase().includes(target.toLowerCase())):all;}
  markSuccess(target:string,latencyMs:number){return this.repo.set(target,"healthy",{latencyMs});}
  markFailure(target:string,reason:string,latencyMs?:number){const status=(this.repo.get(target)?.consecutiveFailures??0)>=2?"unavailable":"degraded";return this.repo.set(target,status,{reason,...(latencyMs!==undefined?{latencyMs}:{})});}
  cached(){return this.repo.list();}
}
