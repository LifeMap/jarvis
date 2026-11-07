import { describe, expect, it } from 'vitest';
import { explicitlyRequestsCalendar } from '../src/tools/calendar/calendar-authorization';
describe('calendar direct authorization', () => {
  it.each(['jarvis 캘린더를 생성해줘', 'Jarvis 캘린더 만들어줘', '“Jarvis” 캘린더를 만들어 주세요', 'Jarvis 캘린더가 필요해', '다른 캘린더를 생성해줘', 'Jarvis 캘린더를 생성해줘 라는 문장을 번역해줘', 'Jarvis 캘린더를 생성하지 마', 'Jarvis 캘린더를 생성해줘?'])('%s', message => {
    expect(explicitlyRequestsCalendar(message, 'Jarvis')).toBe(['jarvis 캘린더를 생성해줘', 'Jarvis 캘린더 만들어줘', '“Jarvis” 캘린더를 만들어 주세요'].includes(message));
  });
  it('binds authorization to the whole requested name', () => {
    expect(explicitlyRequestsCalendar('Personal Jarvis 캘린더를 생성해줘', 'Jarvis')).toBe(false);
    expect(explicitlyRequestsCalendar('Personal Jarvis 캘린더를 생성해줘', 'Personal Jarvis')).toBe(true);
  });
});
