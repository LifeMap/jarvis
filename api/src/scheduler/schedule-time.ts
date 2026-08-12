import type { RecurrenceRule, ScheduleRule, ScheduleType } from "./types";
export function nextRun(type:ScheduleType,rule:ScheduleRule,timezone:string,after=new Date()):Date{
  validateTimezone(timezone);
  if(type==="one_time"){
    if(!("runAt" in rule)) throw new Error("One-time schedule requires runAt");
    const date=new Date(rule.runAt); if(Number.isNaN(date.getTime())||date<=after) throw new Error("runAt must be in the future"); return date;
  }
  if("runAt" in rule) throw new Error("Recurring schedule requires a recurrence rule");
  validateRecurrence(rule);
  for(let offset=0;offset<8;offset++){
    const local=localParts(new Date(after.getTime()+offset*86_400_000),timezone);
    if(rule.frequency==="weekly"&&local.weekday!==rule.weekday) continue;
    const candidate=localToUtc(local.year,local.month,local.day,rule.hour,rule.minute,timezone);
    if(candidate>after) return candidate;
  }
  throw new Error("Could not calculate next occurrence");
}
function validateRecurrence(r:RecurrenceRule){if(!Number.isInteger(r.hour)||r.hour<0||r.hour>23||!Number.isInteger(r.minute)||r.minute<0||r.minute>59)throw new Error("Invalid recurrence time");if(r.frequency==="weekly"&&(!Number.isInteger(r.weekday)||r.weekday<0||r.weekday>6))throw new Error("Invalid weekday")}
function validateTimezone(t:string){try{new Intl.DateTimeFormat("en",{timeZone:t}).format()}catch{throw new Error("Invalid timezone")}}
function localParts(d:Date,t:string){const p=new Intl.DateTimeFormat("en-US",{timeZone:t,year:"numeric",month:"numeric",day:"numeric",weekday:"short"}).formatToParts(d);const get=(x:string)=>Number(p.find(v=>v.type===x)?.value);const wd=["Sun","Mon","Tue","Wed","Thu","Fri","Sat"].indexOf(p.find(v=>v.type==="weekday")?.value??"");return{year:get("year"),month:get("month"),day:get("day"),weekday:wd}}
function localToUtc(y:number,m:number,d:number,h:number,min:number,t:string){let guess=Date.UTC(y,m-1,d,h,min);for(let i=0;i<3;i++){const parts=new Intl.DateTimeFormat("en-US",{timeZone:t,year:"numeric",month:"numeric",day:"numeric",hour:"numeric",minute:"numeric",hourCycle:"h23"}).formatToParts(new Date(guess));const get=(x:string)=>Number(parts.find(v=>v.type===x)?.value);const represented=Date.UTC(get("year"),get("month")-1,get("day"),get("hour"),get("minute"));guess+=Date.UTC(y,m-1,d,h,min)-represented}return new Date(guess)}
