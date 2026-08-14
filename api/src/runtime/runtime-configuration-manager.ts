import type { ModelConfigurationService,ModelState } from "../llm/model-configuration-service";
import type { ModelProviderId } from "../llm/types";
import type { McpRegistryService } from "../mcp/mcp-registry-service";
import type { ToolProviderConfigurationService,ToolProviderState } from "../tools/tool-provider-configuration-service";
import type { DynamicToolService } from "../tools/tool-provider-registry";
import { ToolError } from "../tools/types";
import type { RuntimeConfigurationHistoryRepository,RuntimeChangeSource } from "./runtime-configuration-history-repository";

export type RuntimeChange=
  |{kind:"model.set";provider:ModelProviderId;model?:string}
  |{kind:"model.reset"}
  |{kind:"tool.set";service:DynamicToolService;providerId:string}
  |{kind:"tool.reset";service:DynamicToolService};
export interface RuntimeChangePlanItem{change:RuntimeChange;target:string;previousValue:unknown;newValue:unknown;validation:string[]}

export class RuntimeConfigurationManager{
  constructor(readonly models:ModelConfigurationService,readonly tools:ToolProviderConfigurationService,readonly mcp:McpRegistryService,private readonly history:RuntimeConfigurationHistoryRepository,private readonly transaction:<T>(callback:()=>T)=>T=callback=>callback()){}
  getConfiguration(){return{model:{active:this.models.getActive(),default:this.models.getDefault(),available:this.models.listAvailable().map(({provider,model,enabled,displayName,capabilities})=>({provider,model,enabled,displayName,capabilities}))},tools:Object.fromEntries(this.tools.registry.services().map(service=>[service,{active:this.tools.getActive(service),default:this.tools.getDefault(service),available:this.tools.list(service)}])),mcp:{servers:this.mcp.list().map(server=>({id:server.id,name:server.name,enabled:server.enabled,authType:server.authType,service:server.service,providerId:server.providerId,connection:{state:server.connection.state,connected:server.connection.connected,...(server.connection.error?{error:server.connection.error}:{})},capabilities:Object.keys(server.capabilityMapping)}))}};}
  getSection(section:"model"|"tools"|"mcp"){return this.getConfiguration()[section];}
  getHistory(limit=50){return this.history.list(limit);}
  recordMutation(changeType:string,target:string,previousValue:unknown,newValue:unknown,source:RuntimeChangeSource="user-command"){return this.history.record({changeType,target,previousValue,newValue,source});}
  validateChange(change:RuntimeChange):RuntimeChangePlanItem{
    if(change.kind==="model.set"){const previous=this.models.getActive();const registered=change.model?this.models.registry.get(change.provider,change.model):this.models.registry.defaultForProvider(change.provider);if(!registered)throw new ToolError("Unknown model",`등록되지 않은 모델입니다: ${change.provider}/${change.model??"default"}. 기존 설정은 유지됩니다.`);if(!registered.enabled)throw new ToolError("Unavailable model",`${registered.unavailableReason??"모델을 사용할 수 없습니다."} 기존 설정은 유지됩니다.`);return{change,target:"model",previousValue:modelValue(previous),newValue:{provider:registered.provider,model:registered.model},validation:["provider registered","model registered","provider available"]};}
    if(change.kind==="model.reset"){const previous=this.models.getActive(),next=this.models.getDefault();if(!next.enabled)throw new ToolError("Unavailable default model",`${next.unavailableReason??"기본 모델을 사용할 수 없습니다."} 기존 설정은 유지됩니다.`);return{change,target:"model",previousValue:modelValue(previous),newValue:modelValue(next),validation:["default model registered","provider available"]};}
    const previous=this.tools.getActive(change.service);const provider=change.kind==="tool.reset"?this.tools.registry.get(change.service,this.tools.getDefault(change.service).providerId):this.tools.registry.get(change.service,change.providerId);if(!provider)throw new ToolError("Unknown Tool Provider",`${change.service}에 요청한 Provider가 등록되어 있지 않습니다. 기존 설정은 유지됩니다.`);if(!provider.enabled)throw new ToolError("Unavailable Tool Provider",`${provider.unavailableReason??"Provider를 사용할 수 없습니다."} 기존 설정은 유지됩니다.`);return{change,target:`tools.${change.service}`,previousValue:toolValue(previous),newValue:{service:change.service,providerId:provider.providerId},validation:["service registered","provider registered","provider available",...(provider.type==="mcp"?["MCP connected","required capabilities discovered"]:[])]};
  }
  applyChange(changes:RuntimeChange[],source:RuntimeChangeSource="user-command"){
    if(!changes.length)throw new ToolError("Empty change plan","변경할 설정이 없습니다.");const normalized=changes.map(change=>change.kind==="tool.set"?{...change,providerId:this.resolveProvider(change.service,change.providerId)}:change);const targets=new Set<string>();for(const change of normalized){const target=change.kind==="model.set"||change.kind==="model.reset"?"model":`tools.${change.service}`;if(targets.has(target))throw new ToolError("Duplicate configuration target",`${target} 변경이 한 요청에 중복 지정되었습니다. 기존 설정은 유지됩니다.`);targets.add(target);}const plan=normalized.map(change=>this.validateChange(change));
    return this.transaction(()=>{for(const item of plan)this.apply(item.change);for(const item of plan)this.history.record({changeType:item.change.kind,target:item.target,previousValue:item.previousValue,newValue:item.newValue,source});return{applied:true,plan,configuration:this.getConfiguration()};});
  }
  resetSection(section:"model"|DynamicToolService){return this.applyChange([section==="model"?{kind:"model.reset"}:{kind:"tool.reset",service:section}]);}
  resetAll(){return this.applyChange([{kind:"model.reset"},{kind:"tool.reset",service:"gmail"},{kind:"tool.reset",service:"calendar"},{kind:"tool.reset",service:"search"}]);}
  resolveProvider(service:DynamicToolService,requested:string):string{if(requested==="api")return this.tools.getDefault(service).providerId;if(requested==="mcp"){const matches=this.tools.list(service).filter(item=>item.type==="mcp"&&item.enabled);if(matches.length!==1)throw new ToolError("Ambiguous MCP Provider",matches.length?`${service} MCP Provider가 여러 개입니다. Provider ID를 명시해 주세요.`:`사용 가능한 ${service} MCP Provider가 없습니다. 기존 설정은 유지됩니다.`);return matches[0]!.providerId;}return requested;}
  private apply(change:RuntimeChange){if(change.kind==="model.set")return this.models.setActive(change.provider,change.model);if(change.kind==="model.reset")return this.models.resetToDefault();if(change.kind==="tool.set")return this.tools.setActive(change.service,change.providerId);return this.tools.reset(change.service);}
}
function modelValue(value:ModelState){return{provider:value.provider,model:value.model}}
function toolValue(value:ToolProviderState){return{service:value.service,providerId:value.providerId}}
