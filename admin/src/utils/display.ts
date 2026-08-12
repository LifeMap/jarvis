const labels: Record<string, string> = {
  connected: "연결됨", disconnected: "연결 끊김", available: "사용 가능", unavailable: "사용 불가",
  success: "성공", failed: "실패", completed: "완료", scheduled: "예약됨", running: "실행 중", disabled: "비활성화",
  manual: "수동", recurring: "반복", one_time: "일회성", AUTO: "자동 실행", APPROVAL_REQUIRED: "승인 필요",
  PENDING: "승인 대기", APPROVED: "승인됨", REJECTED: "거부됨", EXECUTED: "실행 완료", FAILED: "실패", EXPIRED: "만료됨",
  "read-only": "읽기 전용", read_only: "읽기 전용", write: "쓰기",
};
export function display(value: string | null | undefined): string { return value ? labels[value] ?? value : "—"; }
const toolDescriptions: Record<string, string> = {
  "gmail.search_messages": "최근 Gmail 메일을 조회하거나 조건에 따라 검색합니다. 읽기 전용입니다.",
  "gmail.send": "새 이메일을 발송합니다. 사용자의 명시적 승인이 필요합니다.",
  "gmail.reply": "기존 Gmail 대화에 답장합니다. 사용자의 명시적 승인이 필요합니다.",
  "google_calendar.search_events": "지정한 기간의 Google Calendar 일정을 조회합니다. 읽기 전용입니다.",
  "calendar.create": "Google Calendar 일정을 생성합니다. 사용자의 명시적 승인이 필요합니다.",
  "calendar.update": "Google Calendar 일정을 수정합니다. 사용자의 명시적 승인이 필요합니다.",
  "calendar.delete": "Google Calendar 일정을 삭제합니다. 사용자의 명시적 승인이 필요합니다.",
  "web_search.search": "최신 정보 또는 변경 가능성이 있는 정보를 공개 웹에서 검색합니다.",
  "scheduler.create": "새 스케줄을 등록합니다.",
};
export function toolDescription(name: string, fallback: string): string { return toolDescriptions[name] ?? fallback; }
