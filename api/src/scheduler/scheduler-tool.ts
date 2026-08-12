import type { ToolContext,ToolDefinition } from "../tools/types";
import type { SchedulerService } from "./scheduler-service";
import type { CreateScheduleInput,JarvisSchedule } from "./types";
export class SchedulerCreateTool implements ToolDefinition<JarvisSchedule>{
  name="scheduler.create";description="Create a one-time or recurring future Agent task. Use for reminders and requests containing a future time or recurrence.";policy="AUTO" as const;requiresApproval=false as const;
  inputSchema={type:"object",properties:{title:{type:"string"},instruction:{type:"string",description:"Action to execute at run time, without scheduling words"},scheduleType:{type:"string",enum:["one_time","recurring"]},scheduleRule:{type:"object",description:'One-time: {"runAt":"RFC3339"}; recurring: {"frequency":"daily"|"weekly","hour":0-23,"minute":0-59,"weekday":0-6 for weekly}'},timezone:{type:"string"}},required:["title","instruction","scheduleType","scheduleRule"]};
  constructor(private readonly service:SchedulerService){}
  execute(input:Record<string,unknown>,context:ToolContext){return this.service.create({...input,timezone:typeof input.timezone==="string"?input.timezone:context.timezone} as unknown as CreateScheduleInput)}
  summarize(r:JarvisSchedule){return `Schedule created: ${r.id}, next run ${r.nextRunAt} (${r.timezone})`}
}
