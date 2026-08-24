# Phase 5 CHECKPOINT 2 — 수신 보고 + 로컬 인코딩 + R2

날짜: 2026-08-24  
상태: 구현 완료 — 실기기 게이트 대기  
브랜치: `phase5`  
근거: `docs/Jarvis_Call_Bridge_Client_PRD.md` Phase 5, §20, §24–26  
선행: Phase 5 CHECKPOINT 1 FINAL PASS (2026-08-24 18:53)

이 문서는 CHECKPOINT 2만 정의한다. 자동 발신, 앱 푸시, 메일, 통화 중 Tool, Keychain, Takeover, Phase 7 풀 녹음 라이프사이클은 여기 없다.

---

## 1. 한 줄 목표

착신 자동응답이 끝나면 Mac이 통화 오디오를 인코딩해 R2에 올리고, 발신자·용건·녹음 경로를 Jarvis에 남긴다. Playground는 알림으로, Admin `통화` 메뉴는 목록으로 본다.

Call Bridge는 주인이 전화로 요청하는 창구가 아니다. 착신 자동응답기다. 자동 발신은 다음 체크포인트다.

---

## 2. 잠근 결정

| 항목 | 결정 |
|---|---|
| 제품 | 착신 자동응답. 주인 발신 요청 없음 |
| 전달 | `/api/calls` 레코드. Playground 채팅 세션에 섞지 않음 |
| Playground | 폴링 + 화면 배너 + 브라우저 Notification(허용 시). 앱 푸시는 나중 |
| Admin | 신규 메뉴 `통화`. History와 별도 |
| 오디오 | Mac에서 RX+TX를 시간축 믹스 → AAC `merged.m4a` → Worker가 R2에 저장 |
| R2 | Worker 바인딩 업로드. Bridge에 R2/S3 키 없음. 버킷 공개 없음 |
| 듣기 | 인증된 `GET /api/calls/{id}/audio`. 보고에 그 경로를 적음 |
| 대화 텍스트 | Realtime 입력/출력 전사. 없으면 요약 지어내지 않음 |
| 발신자 | `{ name, phoneNumber }`. 번호로 연락처를 찾으면 저장된 이름, 없으면 `name="unknown"`. 번호는 항상 넘김. 둘 다 못 읽으면 각각 `"unknown"`. `[CALL]` 로그에는 쓰지 않음 |
| 요약 | complete 시 Agent/LLM이 전사로만 작성. 채팅 세션에 user 메시지로 넣지 않음 |
| 생성 시점 | Realtime **Connected** 직후 `POST /api/calls` |
| 완료 시점 | 통화 Idle 후 인코딩·업로드·`POST .../complete` |
| 실패 정책 | 보고 실패는 route/PCM을 롤백하지 않음. CP1과 같음 |
| session.update | VAD/PCM 유지. 전사만 추가 |
| 드라이버/PCM/mute/barge-in | 수정 없음 |
| Phase 5 COMPLETE | 이 체크포인트 PASS만으로 선언하지 않음 |

---

## 3. 아키텍처

```text
Active + Realtime Connected
  → POST /api/calls                    { caller: { name, phoneNumber }, startedAt }
  → session.update (기존 VAD + 전사)
  → 통화 중 전사 이벤트 수집

Idle
  → RX/TX 디버그 PCM을 시간축 믹스
  → Mac에서 AAC m4a 인코딩
  → PUT /api/calls/{id}/audio          Bearer JARVIS_API_TOKEN
      → CALLS_BUCKET.put(jarvis-call/{id}/merged.m4a)  // 버킷 jarvis
  → POST /api/calls/{id}/complete      { endedAt, transcript }
      → 전사 있으면 요약 생성, 없으면 summary=null
      → status=completed | upload_failed | failed

Playground (탭 열림)
  → 5초마다 GET /api/calls
  → 새 completed 레코드 → 배너 + Notification
  → 배너/상세에 caller, summary, /api/calls/{id}/audio

Admin 통화
  → 같은 GET /api/calls, GET /api/calls/{id}
```

디버그 WAV(`~/Documents/jarvis-call-bridge-rx|tx-*.wav`)는 그대로 둔다. 제품 듣기는 R2의 merged만 쓴다.

---

## 4. API

인증: 기존 `Authorization: Bearer ${JARVIS_API_TOKEN}` (`isAuthorized`).

### `POST /api/calls`

```json
{ "caller": { "name": "unknown", "phoneNumber": "+821012345678" }, "startedAt": "2026-08-24T09:52:59.000Z" }
```

200:

```json
{ "id": "call-...", "status": "active", "caller": { "name": "unknown", "phoneNumber": "+821012345678" }, "startedAt": "..." }
```

`name`은 연락처 표시 이름 또는 `"unknown"`. `phoneNumber`는 읽은 번호 또는 `"unknown"`. 빈 문자열은 쓰지 않는다.

### `GET /api/calls`

최신순. 쿼리 `updatedAfter`(ISO8601) 있으면 그 시각 이후만.

```json
{ "calls": [ { "id", "status", "caller": { "name", "phoneNumber" }, "startedAt", "endedAt", "summary", "hasAudio", "updatedAt" } ] }
```

`transcript`와 R2 키는 목록에 넣지 않는다.

### `GET /api/calls/{id}`

```json
{
  "id": "call-...",
  "status": "completed",
  "caller": { "name": "unknown", "phoneNumber": "+821012345678" },
  "startedAt": "...",
  "endedAt": "...",
  "transcript": [ { "role": "caller"|"jarvis", "text": "..." } ],
  "summary": "거래처에서 금요일 회의를 오후 4시로 옮겨 달라고 했다.",
  "audioPath": "/api/calls/call-.../audio",
  "hasAudio": true,
  "updatedAt": "..."
}
```

### `PUT /api/calls/{id}/audio`

`Content-Type: audio/mp4`. 본문은 m4a 바이트. 최대 40MB. 200 `{ "hasAudio": true }`.

없는 id는 404. 이미 complete된 통화에 덮어쓰기는 거부(409).

### `GET /api/calls/{id}/audio`

인증된 재생/다운로드. `Content-Type: audio/mp4`. 없으면 404.

공개 URL·만료 없는 서명 링크는 만들지 않는다.

### `POST /api/calls/{id}/complete`

```json
{ "endedAt": "...", "transcript": [ { "role": "caller", "text": "..." } ] }
```

- 오디오가 있으면 `completed`
- 오디오 없고 전사는 있으면 `completed` (듣기는 없음)
- 오디오 업로드가 실패한 채 부르면 `upload_failed`
- `transcript`가 비면 `summary`는 `null`. LLM을 부르지 않음
- 전사가 있으면 짧은 한국어 용건 요약만 생성. 없는 사실을 채우지 않음

에러: 401, 404, 409(이미 complete), 413(오디오 과대), 503(R2 없음/실패).

`ek_`, `sk-`, `JARVIS_API_TOKEN`, raw PCM을 로그/에러 detail에 넣지 않는다.

저장: Durable Object SQLite `calls` 테이블. 오디오 바이너리는 SQLite에 넣지 않는다.

---

## 5. Bridge

기존 `JarvisAPIClient` + `.env` origin/token을 재사용한다.

Realtime Connected 직후:

1. 발신자 식별 후 `POST /api/calls`
2. 실패해도 Realtime/PCM/route는 유지. 이후 업로드는 생략

발신자 식별 (보고·API에만 사용, 진단 로그 금지):

1. 착신/통화 배너·Phone.app 스냅샷에서 전화번호로 보이는 문자열을 읽는다. 없으면 `phoneNumber="unknown"`
2. 번호가 있으면 Mac 연락처(`CNContactStore`)에서 같은 번호를 찾는다. 있으면 그 표시 이름을 `name`으로 쓴다
3. 연락처에 없거나 연락처 권한이 없으면 `name="unknown"`. 번호는 그대로 넘긴다
4. 배너에 이름만 있고 번호가 없으면 `name`은 배너 텍스트, `phoneNumber="unknown"` — 이름을 지어내지 않는다

기존 `displayCaller` 단일 문자열은 이 객체로 바꾼다. `[CALL-SCAN]` / `[CALL]`에는 이름·번호를 쓰지 않는다.

`session.update`의 `audio.input`에 전사만 추가한다. `turn_detection`과 PCM 포맷은 CP3와 같다.

통화 중 어댑터가 전사 completed 이벤트를 모아 `[role, text]` 배열을 만든다. 이벤트 이름은 구현 시 OpenAI Realtime 현재 스키마에 맞춘다. 파싱 실패는 건너뛰고 빈 전사를 허용한다.

Idle / disconnect 후(PCM stop·route restore는 기존 순서 유지):

1. 열려 있는 RX/TX 디버그 버퍼로 24 kHz mono PCM16을 시간축 정렬해 믹스
2. AAC m4a로 인코딩
3. `PUT /api/calls/{id}/audio`
4. `POST /api/calls/{id}/complete`

인코딩/업로드 실패 시 complete는 `upload_failed`로 보내고, 전사가 있으면 그대로 넘긴다. 통화 경로를 되돌리지 않는다.

로컬에 제품 m4a를 영구 보관하지 않아도 된다. 임시 파일은 업로드 후 지운다. 디버그 WAV는 기존처럼 Documents에 남긴다.

---

## 6. Playground

탭이 열려 있는 동안 5초마다 `GET /api/calls`를 본다.

이전에 본 `updatedAt`보다 새로운 `completed` / `upload_failed`가 있으면:

- 화면 상단 배너: `name`(`unknown`이면 번호) + 요약(없으면 “녹음을 확인하세요”) + 듣기
- `Notification` 권한이 있으면 브라우저 알림. 매 폴링마다 권한을 다시 묻지 않음

배너는 현재 채팅 메시지 배열에 assistant/user를 추가하지 않는다. 상세는 `/api/calls/{id}`다.

---

## 7. Admin

메뉴에 `통화`를 추가한다. History(Agent 실행)와 분리한다.

목록: 시간, 이름, 번호, 상태, 요약 한 줄, 오디오 여부.  
상세: 이름, 번호, 용건, 전사, `audioPath`로 재생.

앱 푸시·APNs·FCM은 없다. 나중에 같은 `GET /api/calls`를 쓰면 된다.

---

## 8. 테스트

API: 생성/목록/상세, 오디오 PUT/GET, complete 요약(전사 있음/없음), 401, 404, 409, R2 실패 503. 시크릿 미누출.

Bridge: Connected 후 create, Idle 후 encode+upload+complete, create 실패해도 PCM running, 전사 이벤트 수집, session.update VAD 불변. 번호+연락처 매칭 → 이름, 매칭 실패 → `unknown`+번호. 로그 문자열에 번호/이름이 없음.

Playground: 새 call이면 배너가 뜨고 채팅 messages는 그대로.

Admin: `통화` 메뉴가 목록을 렌더한다.

실 OpenAI·실 CoreAudio·실 R2는 단위 테스트에 없다.

---

## 9. 실기기

1. R2 버킷 바인딩을 `jarvis-api.twms.ai`에 배포
2. 실통화 한 통, Connected, 한 턴 이상. 연락처 권한 허용
3. 종료 후 Admin `통화`에 이름·번호가 보임 (미저장이면 이름 `unknown` + 번호)
4. Playground 탭을 열어 두면 배너/알림
5. 인증된 audio 경로로 대화가 들림
6. 로그에 secret 없음. 드라이버 재설치 없음

---

## 10. 완료 판정

```text
PASS
  - api + bridge + web/admin 해당 테스트 통과
  - 실통화 종료 후 Admin에서 보고 확인
  - 녹음이 들림 (전사 없으면 요약은 비어 있어도 PASS)
  - Playground 배너 (탭을 열어 둔 경우)
  - 드라이버 미변경, 키 미커밋

PASS 뒤에 Phase 5 COMPLETE 아님
자동 발신 / 앱 푸시 / 메일은 자동 시작하지 않음
```

---

## 11. 명시적 비범위

- Jarvis를 통한 전화 발신
- 앱 푸시 (APNs/FCM)
- 메일 알림
- 통화 중 Realtime Tool → Agent
- Approval / Scheduler / Keychain
- Playground 채팅 세션에 보고 삽입
- rx.m4a / tx.m4a 분리 보관, Takeover 구간, iPhone Handoff finalize
- 공개 R2 URL, Bridge의 R2 직접 자격 증명
- 발신자 이름/번호를 진단 로그에 남기는 일 (API·Admin·Playground 보고는 허용)
- 드라이버 수정, 070 / SIP
