import type { SqlExecutor } from "../storage/sql";

export type RuntimeChangeSource="user-command"|"system-bootstrap";
export interface RuntimeConfigurationHistoryEntry{id:string;timestamp:string;changeType:string;target:string;previousValue:unknown;newValue:unknown;source:RuntimeChangeSource}
interface Row{id:string;change_type:string;target:string;previous_value_json:string;new_value_json:string;source:RuntimeChangeSource;created_at:string}

export class RuntimeConfigurationHistoryRepository{
  constructor(private readonly db:SqlExecutor){}
  record(input:Omit<RuntimeConfigurationHistoryEntry,"id"|"timestamp">):RuntimeConfigurationHistoryEntry{const id=crypto.randomUUID();const timestamp=new Date().toISOString();this.db.sql`INSERT INTO runtime_configuration_history (id,change_type,target,previous_value_json,new_value_json,source,created_at) VALUES (${id},${input.changeType},${input.target},${JSON.stringify(sanitize(input.previousValue))},${JSON.stringify(sanitize(input.newValue))},${input.source},${timestamp})`;return{id,timestamp,...input,previousValue:sanitize(input.previousValue),newValue:sanitize(input.newValue)};}
  list(limit=50):RuntimeConfigurationHistoryEntry[]{return this.db.sql<Row>`SELECT id,change_type,target,previous_value_json,new_value_json,source,created_at FROM runtime_configuration_history ORDER BY created_at DESC LIMIT ${Math.min(Math.max(limit,1),200)}`.map(row=>({id:row.id,timestamp:row.created_at,changeType:row.change_type,target:row.target,previousValue:JSON.parse(row.previous_value_json),newValue:JSON.parse(row.new_value_json),source:row.source}));}
}
function sanitize(value:unknown):unknown{if(Array.isArray(value))return value.map(sanitize);if(value&&typeof value==="object")return Object.fromEntries(Object.entries(value as Record<string,unknown>).filter(([key])=>!/secret|token|api.?key|authorization|credential|auth.?url/i.test(key)).map(([key,item])=>[key,sanitize(item)]));return value;}
