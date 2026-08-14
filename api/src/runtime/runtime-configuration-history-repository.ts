import type { SqlExecutor } from "../storage/sql";
import { redactValue } from "../security/redaction";

export type RuntimeChangeSource="user-command"|"system-bootstrap";
export interface RuntimeConfigurationHistoryEntry{id:string;timestamp:string;changeType:string;target:string;previousValue:unknown;newValue:unknown;source:RuntimeChangeSource}
interface Row{id:string;change_type:string;target:string;previous_value_json:string;new_value_json:string;source:RuntimeChangeSource;created_at:string}

export class RuntimeConfigurationHistoryRepository{
  constructor(private readonly db:SqlExecutor){}
  record(input:Omit<RuntimeConfigurationHistoryEntry,"id"|"timestamp">):RuntimeConfigurationHistoryEntry{const id=crypto.randomUUID();const timestamp=new Date().toISOString();const previousValue=redactValue(input.previousValue),newValue=redactValue(input.newValue);this.db.sql`INSERT INTO runtime_configuration_history (id,change_type,target,previous_value_json,new_value_json,source,created_at) VALUES (${id},${input.changeType},${input.target},${JSON.stringify(previousValue)},${JSON.stringify(newValue)},${input.source},${timestamp})`;return{id,timestamp,...input,previousValue,newValue};}
  list(limit=50):RuntimeConfigurationHistoryEntry[]{return this.db.sql<Row>`SELECT id,change_type,target,previous_value_json,new_value_json,source,created_at FROM runtime_configuration_history ORDER BY created_at DESC LIMIT ${Math.min(Math.max(limit,1),200)}`.map(row=>({id:row.id,timestamp:row.created_at,changeType:row.change_type,target:row.target,previousValue:JSON.parse(row.previous_value_json),newValue:JSON.parse(row.new_value_json),source:row.source}));}
}
