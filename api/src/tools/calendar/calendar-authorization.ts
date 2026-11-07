import { normalizeCalendarName } from './calendar-catalog';

// Match a complete direct command, never a substring in quoted instructions,
// a question, or an inferred calendar name. Unrecognized wording falls back to approval.
export function explicitlyRequestsCalendar(message: string, name: unknown): boolean {
  if (typeof name !== 'string' || !name.trim()) return false;
  const text = message.normalize('NFC').trim();
  const patterns = [
    /^(?:부탁해요[,，]?\s*|제발\s*)?["'“‘]?(.+?)["'”’]?(?:\s*라는\s*이름의|\s*이름의)?\s+캘린더(?:를|는)?\s*(?:없으면\s*)?(?:생성|추가|만들어)(?:해\s*줘|해\s*주세요|해\s*주십시오|\s*줘|\s*주세요|\s*주십시오)[.!。]*$/iu,
    /^캘린더(?:를)?\s+["'“‘]?(.+?)["'”’]?(?:으)?로\s*(?:생성해|만들어)\s*(?:줘|주세요)[.!。]*$/iu,
    /^(?:please\s+)?(?:create|add)\s+(?:a\s+)?calendar\s+(?:named\s+|called\s+)["']?(.+?)["']?[.!]*$/iu,
  ];
  return patterns.some(pattern => {
    const match = text.match(pattern);
    return match && normalizeCalendarName(match[1]!) === normalizeCalendarName(name);
  });
}
