import type { SqlExecutor } from '../../storage/sql';
import { ToolError, type ToolDefinition, type ToolContext } from '../types';
export interface NamedCalendar { id:string; name:string; writable:boolean }
export interface EnsureCalendarResult { created:boolean; calendars:NamedCalendar[] }
export interface CalendarCatalogClient { ensureCalendar(input:{name:string;timezone:string}):Promise<EnsureCalendarResult> }
export function normalizeCalendarName(name:string){return name.normalize('NFC').trim().toLowerCase();}
export class CalendarCreationRepository {
  constructor(private db:SqlExecutor){db.sql`CREATE TABLE IF NOT EXISTS calendar_creation_guards (name TEXT PRIMARY KEY, created_at TEXT NOT NULL)`;}
  reserve(name:string):boolean {return this.db.sql`INSERT OR IGNORE INTO calendar_creation_guards VALUES (${normalizeCalendarName(name)},${new Date().toISOString()}) RETURNING name`.length===1;}
  release(name:string){this.db.sql`DELETE FROM calendar_creation_guards WHERE name=${normalizeCalendarName(name)}`;}
}
export class CalendarEnsureTool implements ToolDefinition<EnsureCalendarResult> {
  name='calendar.ensure_calendar';
  description='요청한 이름의 Google 캘린더를 숨김 항목까지 조회합니다. 같은 이름이 있으면 기존 캘린더와 쓰기 가능 여부를 반환하고, 없을 때만 새 캘린더를 생성합니다. 일정이 아닌 캘린더 자체를 만드는 기능이며 사용자의 명시적 승인이 필요합니다. 읽기 전용 캘린더가 있어도 중복 생성하지 않습니다.';
  policy='APPROVAL_REQUIRED' as const;requiresApproval=true;
  inputSchema={type:'object',properties:{name:{type:'string',description:'조회하거나 생성할 캘린더 이름',minLength:1,maxLength:200}},required:['name'],additionalProperties:false};
  constructor(private client:CalendarCatalogClient){}
  async execute(input:Record<string,unknown>,context:ToolContext){
    if(typeof input.name!=='string'||!input.name.trim()||input.name.length>200||/[\u0000-\u001f\u007f]/.test(input.name))throw new ToolError('Invalid calendar name','캘린더 이름은 1~200자의 텍스트여야 합니다.');
    try {return await this.client.ensureCalendar({name:input.name.normalize('NFC').trim(),timezone:context.timezone});}
    catch(error){if(error instanceof ToolError)throw error;throw new ToolError('Calendar creation failed','캘린더 조회 또는 생성에 실패했습니다. 생성 결과가 불확실한 경우 중복 방지를 위해 자동 재생성하지 않습니다.',{cause:error});}
  }
  summarize(result:EnsureCalendarResult){return result.created?`캘린더 생성 완료: ${result.calendars[0]?.name}`:`동일한 이름의 기존 캘린더 ${result.calendars.length}개를 찾았습니다. 새로 생성하지 않았습니다.${result.calendars.some(c=>c.writable)?'':' 쓰기 권한이 없습니다.'}`;}
}
export function calendarCapabilities(scopes?:string[]):string[]{
 const has=(suffix:string)=>scopes?.includes('https://www.googleapis.com/auth/'+suffix);
 const full=has('calendar');
 const capabilities=!scopes||full||has('calendar.events')?['read','create','update','delete']:has('calendar.readonly')?['read']:[];
 if((full||has('calendar.calendarlist.readonly')||has('calendar.calendarlist')||has('calendar.readonly'))&&(full||has('calendar.app.created')||has('calendar.calendars')))capabilities.push('ensure_calendar');
 return capabilities;
}
