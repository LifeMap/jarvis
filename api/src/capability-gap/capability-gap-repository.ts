import type { SqlExecutor } from "../storage/sql";
import { redactText } from "../security/redaction";

export type CapabilityGapStatus="unresolved"|"reviewed"|"ignored";
export interface CapabilityGap{id:string;createdAt:string;updatedAt:string;requestText:string;requestedCapability:string;service:string|null;label:"code-required";reason:string;status:CapabilityGapStatus}
interface Row{id:string;created_at:string;updated_at:string;request_text:string;requested_capability:string;service:string|null;label:"code-required";reason:string;status:CapabilityGapStatus}

export class CapabilityGapRepository{
  constructor(private readonly db:SqlExecutor){}
  create(input:{requestText:string;requestedCapability:string;service?:string|null;reason:string}){const id=crypto.randomUUID(),now=new Date().toISOString();this.db.sql`INSERT INTO capability_gaps (id,request_text,requested_capability,service,label,reason,status,created_at,updated_at) VALUES (${id},${redactText(input.requestText)},${redactText(input.requestedCapability)},${input.service??null},'code-required',${redactText(input.reason)},'unresolved',${now},${now})`;return this.get(id)!;}
  get(id:string){const[row]=this.db.sql<Row>`SELECT id,request_text,requested_capability,service,label,reason,status,created_at,updated_at FROM capability_gaps WHERE id=${id}`;return row?map(row):undefined;}
  list(filter:{status?:CapabilityGapStatus;service?:string;from?:string;to?:string}={}){const status=filter.status??null,service=filter.service??null,from=filter.from??null,to=filter.to??null;return this.db.sql<Row>`SELECT id,request_text,requested_capability,service,label,reason,status,created_at,updated_at FROM capability_gaps WHERE (${status} IS NULL OR status=${status}) AND (${service} IS NULL OR service=${service}) AND (${from} IS NULL OR created_at>=${from}) AND (${to} IS NULL OR created_at<=${to}) ORDER BY created_at DESC LIMIT 500`.map(map);}
  updateStatus(id:string,status:CapabilityGapStatus){const now=new Date().toISOString();this.db.sql`UPDATE capability_gaps SET status=${status},updated_at=${now} WHERE id=${id}`;return this.get(id);}
  summary(){return this.db.sql<{service:string|null;requested_capability:string;count:number;latest_at:string}>`SELECT service,requested_capability,COUNT(*) AS count,MAX(created_at) AS latest_at FROM capability_gaps GROUP BY service,requested_capability ORDER BY count DESC,latest_at DESC`.map(row=>({service:row.service,requestedCapability:row.requested_capability,count:row.count,latestAt:row.latest_at}));}
}
function map(row:Row):CapabilityGap{return{id:row.id,requestText:row.request_text,requestedCapability:row.requested_capability,service:row.service,label:row.label,reason:row.reason,status:row.status,createdAt:row.created_at,updatedAt:row.updated_at}}
