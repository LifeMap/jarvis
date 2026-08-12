import type { SqlExecutor } from "../storage/sql";
import type { JarvisSchedule, ScheduleRule, ScheduleStatus, ScheduleType } from "./types";

export class ScheduleRepository {
  constructor(private readonly database: SqlExecutor) {}
  create(input: { id: string; title: string; instruction: string; scheduleType: ScheduleType; scheduleRule: ScheduleRule; timezone: string; nextRunAt: string }): JarvisSchedule {
    const now = new Date().toISOString();
    this.database.sql`INSERT INTO schedules (id,title,instruction,schedule_type,schedule_rule_json,timezone,enabled,status,created_at,updated_at,next_run_at)
      VALUES (${input.id},${input.title},${input.instruction},${input.scheduleType},${JSON.stringify(input.scheduleRule)},${input.timezone},1,'scheduled',${now},${now},${input.nextRunAt})`;
    return this.get(input.id)!;
  }
  get(id: string): JarvisSchedule | null { const [row] = this.database.sql<Row>`SELECT * FROM schedules WHERE id=${id}`; return row ? map(row) : null; }
  list(): JarvisSchedule[] { return this.database.sql<Row>`SELECT * FROM schedules ORDER BY created_at DESC LIMIT 100`.map(map); }
  setNativeId(id: string, nativeId: string | null) { this.database.sql`UPDATE schedules SET native_schedule_id=${nativeId},updated_at=${new Date().toISOString()} WHERE id=${id}`; }
  update(id: string, input: { title: string; instruction: string; rule: ScheduleRule; timezone: string; enabled: boolean; status: ScheduleStatus; nextRunAt: string | null }): JarvisSchedule | null {
    const [row] = this.database.sql<Row>`UPDATE schedules SET title=${input.title},instruction=${input.instruction},schedule_rule_json=${JSON.stringify(input.rule)},timezone=${input.timezone},enabled=${input.enabled?1:0},status=${input.status},next_run_at=${input.nextRunAt},updated_at=${new Date().toISOString()} WHERE id=${id} RETURNING *`;
    return row ? map(row) : null;
  }
  delete(id: string): boolean { return this.database.sql<{id:string}>`DELETE FROM schedules WHERE id=${id} RETURNING id`.length === 1; }
  claim(id: string): JarvisSchedule | null { const now=new Date().toISOString(); const stale=new Date(Date.now()-15*60_000).toISOString(); const [row]=this.database.sql<Row>`UPDATE schedules SET status='running',last_run_at=${now},updated_at=${now} WHERE id=${id} AND enabled=1 AND (status IN ('scheduled','failed') OR (status='running' AND updated_at<${stale})) RETURNING *`; return row?map(row):null; }
  finish(id: string, status: ScheduleStatus, nextRunAt: string | null, result: string) { this.database.sql`UPDATE schedules SET status=${status},next_run_at=${nextRunAt},last_result=${result},updated_at=${new Date().toISOString()} WHERE id=${id} AND status='running'`; }
  startExecution(id:string,scheduleId:string,trigger:"manual"|"scheduled") { this.database.sql`INSERT INTO schedule_executions (id,schedule_id,trigger_type,started_at) VALUES (${id},${scheduleId},${trigger},${new Date().toISOString()})`; }
  finishExecution(id:string,success:boolean,response:string|null,error:string|null,toolCalls:unknown) { this.database.sql`UPDATE schedule_executions SET completed_at=${new Date().toISOString()},success=${success?1:0},response=${response},error_message=${error},tool_calls_json=${JSON.stringify(toolCalls)} WHERE id=${id}`; }
  executions(scheduleId?:string) { return scheduleId ? this.database.sql<Record<string,unknown>>`SELECT * FROM schedule_executions WHERE schedule_id=${scheduleId} ORDER BY started_at DESC` : this.database.sql<Record<string,unknown>>`SELECT * FROM schedule_executions ORDER BY started_at DESC LIMIT 100`; }
}
interface Row { id:string;title:string;instruction:string;schedule_type:ScheduleType;schedule_rule_json:string;timezone:string;enabled:number;status:ScheduleStatus;native_schedule_id:string|null;created_at:string;updated_at:string;last_run_at:string|null;next_run_at:string|null;last_result:string|null }
function map(r:Row):JarvisSchedule{return{id:r.id,title:r.title,instruction:r.instruction,scheduleType:r.schedule_type,scheduleRule:JSON.parse(r.schedule_rule_json) as ScheduleRule,timezone:r.timezone,enabled:Boolean(r.enabled),status:r.status,nativeScheduleId:r.native_schedule_id,createdAt:r.created_at,updatedAt:r.updated_at,lastRunAt:r.last_run_at,nextRunAt:r.next_run_at,lastResult:r.last_result}}
