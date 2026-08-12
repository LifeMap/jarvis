import { ScheduleRepository } from "./schedule-repository";
import { nextRun } from "./schedule-time";
import type { CreateScheduleInput, JarvisSchedule, UpdateScheduleInput } from "./types";

interface SchedulerHost {
  schedule(when: Date, callback: "executeScheduledTask", payload: { scheduleId: string }, options?: { idempotent?: boolean }): Promise<{ id: string }>;
  cancelSchedule(id: string): Promise<boolean>;
}
export class SchedulerService {
  constructor(private readonly repository:ScheduleRepository,private readonly host:SchedulerHost,private readonly defaultTimezone:string){}
  async create(raw:CreateScheduleInput):Promise<JarvisSchedule>{
    const timezone=raw.timezone??this.defaultTimezone; const at=nextRun(raw.scheduleType,raw.scheduleRule,timezone);
    const input={id:crypto.randomUUID(),title:required(raw.title,"title"),instruction:required(raw.instruction,"instruction"),scheduleType:raw.scheduleType,scheduleRule:raw.scheduleRule,timezone,nextRunAt:at.toISOString()};
    const saved=this.repository.create(input);
    try{const native=await this.host.schedule(at,"executeScheduledTask",{scheduleId:saved.id},{idempotent:true});this.repository.setNativeId(saved.id,native.id);return this.repository.get(saved.id)!}catch(error){this.repository.delete(saved.id);throw error}
  }
  async update(id:string,patch:UpdateScheduleInput):Promise<JarvisSchedule|null>{
    const old=this.repository.get(id);if(!old)return null;if(old.nativeScheduleId)await this.host.cancelSchedule(old.nativeScheduleId);
    const enabled=patch.enabled??old.enabled, timezone=patch.timezone??old.timezone, rule=patch.scheduleRule??old.scheduleRule;
    const at=enabled?nextRun(old.scheduleType,rule,timezone):null;
    this.repository.update(id,{title:patch.title??old.title,instruction:patch.instruction??old.instruction,rule,timezone,enabled,status:enabled?"scheduled":"disabled",nextRunAt:at?.toISOString()??null});
    if(at){const native=await this.host.schedule(at,"executeScheduledTask",{scheduleId:id},{idempotent:true});this.repository.setNativeId(id,native.id)}else this.repository.setNativeId(id,null);
    return this.repository.get(id);
  }
  async delete(id:string){const old=this.repository.get(id);if(!old)return false;if(old.nativeScheduleId)await this.host.cancelSchedule(old.nativeScheduleId);return this.repository.delete(id)}
  async rescheduleRecurring(schedule:JarvisSchedule){const at=nextRun("recurring",schedule.scheduleRule,schedule.timezone,new Date());const native=await this.host.schedule(at,"executeScheduledTask",{scheduleId:schedule.id},{idempotent:true});this.repository.setNativeId(schedule.id,native.id);return at}
}
function required(v:unknown,name:string){if(typeof v!=="string"||!v.trim()||v.length>10_000)throw new Error(`Invalid ${name}`);return v.trim()}
