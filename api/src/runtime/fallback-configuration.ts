import type{ModelConfigurationService}from"../llm/model-configuration-service";
import type{ModelProviderId}from"../llm/types";
import type{SqlExecutor}from"../storage/sql";
import type{ToolProviderConfigurationService}from"../tools/tool-provider-configuration-service";
import type{DynamicToolService}from"../tools/tool-provider-registry";
import{ToolError}from"../tools/types";
import type{FailureClassification}from"./provider-health";

export type FallbackTarget="model"|`tools.${DynamicToolService}`;
export interface FallbackSelection{target:FallbackTarget;providerId:string;model?:string;updatedAt:string}
interface Row{target:string;provider_id:string;model_id:string|null;updated_at:string}
export interface FallbackEvent{id:string;timestamp:string;target:string;primaryProvider:string;fallbackProvider:string;failureType:string;fallbackResult:"success"|"failed"|"blocked"}
interface EventRow{id:string;target:string;primary_provider:string;fallback_provider:string;failure_type:string;fallback_result:"success"|"failed"|"blocked";created_at:string}

export class FallbackConfigurationRepository{
  constructor(private readonly db:SqlExecutor){}
  get(target:FallbackTarget):FallbackSelection|undefined{const[row]=this.db.sql<Row>`SELECT target,provider_id,model_id,updated_at FROM runtime_fallback_configuration WHERE target=${target}`;return row?map(row):undefined;}
  list():FallbackSelection[]{return this.db.sql<Row>`SELECT target,provider_id,model_id,updated_at FROM runtime_fallback_configuration ORDER BY target`.map(map);}
  set(target:FallbackTarget,providerId:string,model?:string){const updatedAt=new Date().toISOString();this.db.sql`INSERT INTO runtime_fallback_configuration (target,provider_id,model_id,updated_at) VALUES (${target},${providerId},${model??null},${updatedAt}) ON CONFLICT(target) DO UPDATE SET provider_id=excluded.provider_id,model_id=excluded.model_id,updated_at=excluded.updated_at`;return this.get(target)!;}
  remove(target:FallbackTarget){const existing=this.get(target);if(existing)this.db.sql`DELETE FROM runtime_fallback_configuration WHERE target=${target}`;return existing;}
  recordEvent(input:Omit<FallbackEvent,"id"|"timestamp">){const id=crypto.randomUUID(),timestamp=new Date().toISOString();this.db.sql`INSERT INTO fallback_events (id,target,primary_provider,fallback_provider,failure_type,fallback_result,created_at) VALUES (${id},${input.target},${input.primaryProvider},${input.fallbackProvider},${input.failureType},${input.fallbackResult},${timestamp})`;return{id,timestamp,...input};}
  events(limit=50):FallbackEvent[]{return this.db.sql<EventRow>`SELECT id,target,primary_provider,fallback_provider,failure_type,fallback_result,created_at FROM fallback_events ORDER BY created_at DESC LIMIT ${Math.min(Math.max(limit,1),200)}`.map(row=>({id:row.id,timestamp:row.created_at,target:row.target,primaryProvider:row.primary_provider,fallbackProvider:row.fallback_provider,failureType:row.failure_type,fallbackResult:row.fallback_result}));}
}
function map(row:Row):FallbackSelection{return{target:row.target as FallbackTarget,providerId:row.provider_id,...(row.model_id?{model:row.model_id}:{}),updatedAt:row.updated_at}}

export class FallbackConfigurationService{
  constructor(private readonly repo:FallbackConfigurationRepository,private readonly models:ModelConfigurationService,private readonly tools:ToolProviderConfigurationService){}
  get(target:FallbackTarget){return this.repo.get(target)}list(){return this.repo.list()}events(limit=50){return this.repo.events(limit)}
  setModel(provider:ModelProviderId,model?:string){const active=this.models.getActive();const registered=model?this.models.registry.get(provider,model):this.models.registry.defaultForProvider(provider);if(!registered||!registered.enabled)throw new ToolError("Invalid model fallback",`${registered?.unavailableReason??"사용 가능한 fallback 모델이 아닙니다."} 기존 fallback 설정은 유지됩니다.`);if(active.provider===registered.provider&&active.model===registered.model)throw new ToolError("Fallback equals active","Active 모델과 fallback 모델은 같을 수 없습니다.");return this.repo.set("model",registered.provider,registered.model);}
  setTool(service:DynamicToolService,providerId:string){const active=this.tools.getActive(service);const provider=this.tools.registry.get(service,providerId);if(!provider||!provider.enabled)throw new ToolError("Invalid Tool fallback",`${provider?.unavailableReason??"사용 가능한 fallback Provider가 아닙니다."} 기존 fallback 설정은 유지됩니다.`);if(active.providerId===providerId)throw new ToolError("Fallback equals active","Active Provider와 fallback Provider는 같을 수 없습니다.");return this.repo.set(`tools.${service}`,providerId);}
  remove(target:FallbackTarget){return this.repo.remove(target)}
  event(target:FallbackTarget,primary:string,fallback:string,failure:FailureClassification,result:"success"|"failed"|"blocked"){return this.repo.recordEvent({target,primaryProvider:primary,fallbackProvider:fallback,failureType:failure.type,fallbackResult:result});}
}
