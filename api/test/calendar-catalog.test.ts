import { describe,it,expect,vi } from 'vitest';
import { GoogleCalendarClient } from '../src/tools/calendar/calendar-client';
import { CalendarEnsureTool, calendarCapabilities, normalizeCalendarName } from '../src/tools/calendar/calendar-catalog';
import { ToolRegistry } from '../src/tools/tool-registry';
import { createToolProviders } from '../src/tools/provider-factory';
import type { Env } from '../src/env';
function guard(){const names=new Set<string>();return {reserve:(name:string)=>{const key=normalizeCalendarName(name);if(names.has(key))return false;names.add(key);return true;},release:(name:string)=>{names.delete(normalizeCalendarName(name));}};}
const input={name:'Jarvis',timezone:'Asia/Seoul'};
describe('calendar.ensure_calendar',()=>{
 it('searches all pages including hidden calendars and returns read-only matches without POST',async()=>{
  const fetcher=vi.fn(async(url:RequestInfo|URL)=>{
   const u=new URL(String(url));expect(u.searchParams.get('showHidden')).toBe('true');
   return Response.json(u.searchParams.has('pageToken')?{items:[{id:'existing',summary:' JARVIS ',accessRole:'reader'}]}:{items:[{id:'other',summary:'Work'}],nextPageToken:'next'});
  });
  const result=await new GoogleCalendarClient(async()=> 'token',fetcher,guard()).ensureCalendar(input);
  expect(result).toEqual({created:false,calendars:[{id:'existing',name:' JARVIS ',writable:false}]});expect(fetcher).toHaveBeenCalledTimes(2);
 });
 it('creates only after complete absence and keeps requested name and timezone',async()=>{
  const fetcher=vi.fn(async(_url:RequestInfo|URL,init?:RequestInit)=>{
   if(init?.method==='POST'){expect(JSON.parse(String(init.body))).toEqual({summary:'개발팀',timeZone:'Asia/Seoul'});return Response.json({id:'new',summary:'개발팀'});}
   return Response.json({items:[]});
  });
  expect(await new GoogleCalendarClient(async()=> 'token',fetcher,guard()).ensureCalendar({...input,name:'개발팀'})).toEqual({created:true,calendars:[{id:'new',name:'개발팀',writable:true}]});
 });
 it('does not create when listing fails or pagination repeats',async()=>{
  for(const response of [()=>new Response('',{status:403}),()=>Response.json({items:[],nextPageToken:'repeat'})]){
   const fetcher=vi.fn(async(_url:RequestInfo|URL,init?:RequestInit)=>{expect(init?.method).not.toBe('POST');return response();});
   await expect(new GoogleCalendarClient(async()=> 'token',fetcher,guard()).ensureCalendar(input)).rejects.toThrow();
  }
 });
 it('prevents duplicate creation across concurrent clients and visibility delay',async()=>{
  const shared=guard();let posts=0;
  const fetcher=vi.fn(async(_url:RequestInfo|URL,init?:RequestInit)=>{if(init?.method==='POST'){posts++;return Response.json({id:'new'});}return Response.json({items:[]});});
  const results=await Promise.allSettled([1,2].map(()=>new GoogleCalendarClient(async()=> 'token',fetcher,shared).ensureCalendar(input)));
  expect(posts).toBe(1);expect(results.filter(r=>r.status==='fulfilled')).toHaveLength(1);
 });
 it('does not retry uncertain POST, but recovers if later listing confirms creation',async()=>{
  const shared=guard();let found=false,posts=0;
  const fetcher=vi.fn(async(_url:RequestInfo|URL,init?:RequestInit)=>{if(init?.method==='POST'){posts++;throw new Error('timeout');}return Response.json({items:found?[{id:'new',summary:'Jarvis',accessRole:'owner'}]:[]});});
  const client=new GoogleCalendarClient(async()=> 'token',fetcher,shared);
  await expect(client.ensureCalendar(input)).rejects.toThrow();await expect(client.ensureCalendar(input)).rejects.toThrow();expect(posts).toBe(1);
  found=true;expect((await client.ensureCalendar(input)).created).toBe(false);
 });
 it('rejects blank names before any external request',async()=>{
  const ensureCalendar=vi.fn();const tool=new CalendarEnsureTool({ensureCalendar});
  await expect(tool.execute({name:'  '},{timezone:'Asia/Seoul'})).rejects.toThrow();expect(ensureCalendar).not.toHaveBeenCalled();
 });
 it('requires approval and separate list plus create scopes',async()=>{
  const prefix='https://www.googleapis.com/auth/';
  expect(calendarCapabilities([prefix+'calendar.events'])).not.toContain('ensure_calendar');
  expect(calendarCapabilities([prefix+'calendar.app.created'])).not.toContain('ensure_calendar');
  expect(calendarCapabilities([prefix+'calendar.calendarlist.readonly',prefix+'calendar.app.created'])).toContain('ensure_calendar');
  const providers=createToolProviders({} as Env,{getAccessToken:async()=> 'token',status:()=>({scopes:[prefix+'calendar.events']})});
  const registry=new ToolRegistry(providers);
  await expect(registry.execute('calendar.ensure_calendar',{name:'Jarvis'},{timezone:'Asia/Seoul'})).rejects.toMatchObject({code:'APPROVAL_REQUIRED'});
  await expect(registry.execute('calendar.ensure_calendar',{name:'Jarvis'},{timezone:'Asia/Seoul'},{approvalId:'a',toolName:'calendar.ensure_calendar'})).rejects.toMatchObject({code:'POLICY_MISMATCH',message:expect.stringContaining('캘린더 목록 조회·생성 권한')});
 });
});
