# 캘린더 자체 생성 툴

`calendar.ensure_calendar`은 일정(event)이 아닌 Google 보조 캘린더를 준비한다.
예: “프로젝트 A 캘린더가 없으면 만들어줘”. 인자는 `{ "name": "프로젝트 A" }`.

- 이름을 지정한 직접 생성 요청은 그 요청을 승인으로 기록하고 즉시 실행한다. 이름이 불명확하거나 Jarvis가 제안한 생성은 별도 승인을 받는다. 다른 변경 툴의 승인 정책은 유지한다.
- 목록을 숨김 캘린더 포함, 모든 페이지 조회 후 이름을 비교한다.
- 이름은 NFC, 앞뒤 공백 제거, 소문자 기준으로 비교한다. 내부 공백은 보존한다.
- 동일한 이름이 있으면 기존 목록과 writable 여부를 반환하고 생성하지 않는다. 읽기 전용인 경우에도 복제하지 않는다.
- 없으면 사용자 프로필 시간대로 생성한다.
- 같은 이름의 생성은 Durable Object SQLite 예약 행으로 직렬화한다. 타임아웃/불확실한 오류는 예약을 유지하여 자동 재생성을 막는다. 이후 목록에서 확인되면 해제한다.
- Google 화면 등 Jarvis 외부의 동시 생성까지 원자적으로 막을 수는 없다.
- 생성 결과 불확실 상태가 계속되면 Google에서 확인 후 관리자가 예약 행을 점검해야 한다. 타이머로 자동 해제하지 않는다.
- 캘린더 목록 조회 실패·페이지 누락·반복 토큰은 생성하지 않고 오류 처리한다.
- MCP 캘린더 제공자에는 생성 기능을 임의로 추정하지 않는다. 이 툴은 Google API 클라이언트에 등록된다.

## 권한과 운영

기존 `calendar.events`만으로는 이 기능을 실행하지 않는다. OAuth에
`calendar.calendarlist.readonly`와 `calendar.app.created`를 추가했다.
기존 사용자는 Google 연결을 다시 승인해야 한다. 전체 calendar 권한 또는
목록 조회와 calendars 권한 조합도 지원한다. 연결 해제부터 할 필요는 없다.
Google 공식 참조:
https://developers.google.com/workspace/calendar/api/v3/reference/calendarList/list
https://developers.google.com/workspace/calendar/api/v3/reference/calendars/insert

실제 사용자 캘린더 생성은 개발 테스트에 포함하지 않는다. 모의 Google API로
목록 페이지, 기존/읽기 전용 캘린더, 생성, 동시 요청, 불확실한 응답, 승인/권한을 검증한다.
Android 전화의 도구는 기존 일정 조회/가예약만 유지한다. 새 캘린더 준비는 사용자의 Jarvis 대화에서 수행한다.
