export interface CallSettings {
  outboundEnabled?: boolean;
  answerDelaySeconds: number;
  greeting: string;
  style: string;
  calendarEnabled: boolean;
}
export const defaultCallSettings: CallSettings = {
  answerDelaySeconds: 3,
  greeting: '안녕하세요, 저는 김재경님의 AI 비서입니다. 말씀 남겨주시면 전달하겠습니다.',
  style: '존댓말로 간결하고 정확하게, 보통 1~2문장으로 답변합니다.',
  calendarEnabled: true,
};
export function validCallSettings(value: unknown): value is CallSettings {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const b = value as Record<string, unknown>;
  return Object.keys(b).every(k => ['answerDelaySeconds','greeting','style','calendarEnabled','outboundEnabled'].includes(k))
    && Number.isInteger(b.answerDelaySeconds) && Number(b.answerDelaySeconds) >= 0 && Number(b.answerDelaySeconds) <= 30
    && typeof b.greeting === 'string' && b.greeting.trim().length > 0 && b.greeting.length <= 500
    && typeof b.style === 'string' && b.style.trim().length > 0 && b.style.length <= 1000
    && typeof b.calendarEnabled === 'boolean'
    && (b.outboundEnabled === undefined || typeof b.outboundEnabled === 'boolean');
}
