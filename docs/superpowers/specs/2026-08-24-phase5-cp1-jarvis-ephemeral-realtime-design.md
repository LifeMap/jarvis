# Phase 5 CHECKPOINT 1 — Jarvis 인증 + ephemeral Realtime 키

날짜: 2026-08-24  
상태: 구현됨. 실기기 게이트 전  
브랜치: `phase5`  
근거: `docs/Jarvis_Call_Bridge_Client_PRD.md` Phase 5, §20, §21  
선행: Phase 4 COMPLETE (2026-08-24)

이 문서는 CHECKPOINT 1만 정의한다. Memory, Tool call, Approval, Scheduler, Keychain, 녹음은 여기 없다.

---

## 1. 한 줄 목표

Call Bridge가 `OPENAI_API_KEY`를 직접 쓰지 않고, Jarvis API Bearer로 short-lived Realtime client secret을 받아 OpenAI WebSocket에 붙는다. 기존 PCM·여러 턴·끼어들기는 그대로다.

---

## 2. 잠근 결정

| 항목 | 결정 |
|---|---|
| 범위 | 인증 + ephemeral 키만 |
| API | `POST /api/realtime/client-secret` — 기존 `isAuthorized` 뒤 |
| OpenAI | 서버가 `POST https://api.openai.com/v1/realtime/client_secrets` 호출. Worker `OPENAI_API_KEY` |
| 응답 | `{ value, expiresAt, model }` 만. secret을 로그에 쓰지 않음 |
| TTL | OpenAI `expires_after.seconds = 600` |
| Bridge 인증 | `bridge/.env`의 `JARVIS_API_TOKEN` + `JARVIS_API_ORIGIN` |
| Keychain | CP1 밖 |
| OpenAI 키 fallback | 없음. Jarvis 실패면 `uiState = .failed`, route/PCM 롤백 없음 |
| session.update | 클라이언트가 유지. 서버 mint body에 turn_detection 없음 |
| 모델 | 요청/env 없으면 `gpt-realtime-2.1-mini` |
| 드라이버/PCM/mute/barge-in | 수정 없음 |
| Phase 5 COMPLETE | 이 체크포인트 PASS만으로 선언하지 않음 |

---

## 3. 아키텍처

```text
Bridge
  → POST /api/realtime/client-secret  Authorization: Bearer JARVIS_API_TOKEN
  → Jarvis API
      → POST /v1/realtime/client_secrets  Authorization: Bearer OPENAI_API_KEY
      → { value: ek_..., expires_at, session.model }
  → Bridge WSS wss://api.openai.com/v1/realtime?model=...
      Authorization: Bearer ek_...
  → session.update (PCM + server_vad, CP3와 동일)
```

PCM 경로(Continuity 탭 → RX → OpenAI → TX → Inject)는 Phase 4와 같다.

---

## 4. API

경로: `POST /api/realtime/client-secret`  
인증: 기존 `Authorization: Bearer ${JARVIS_API_TOKEN}`

요청 body는 선택. 있으면 `{ "model": "gpt-realtime-2.1-mini" }`. 없거나 빈 값이면 기본 모델.

성공 200:

```json
{ "value": "ek_...", "expiresAt": 1756310470, "model": "gpt-realtime-2.1-mini" }
```

실패:

| 상태 | 조건 |
|---|---|
| 401 | Bearer 없음/틀림 |
| 503 | Worker `OPENAI_API_KEY` 없음, 또는 OpenAI 호출 실패 |

OpenAI 요청:

```text
POST https://api.openai.com/v1/realtime/client_secrets
expires_after.anchor = created_at
expires_after.seconds = 600
session.type = realtime
session.model = <요청 또는 기본>
```

mint body에 instructions / turn_detection / tools를 넣지 않는다. 세션 설정은 Bridge `session.update`가 한다.

`value`와 `JARVIS_API_TOKEN`을 `console.log` / Worker 로그 / 에러 detail에 넣지 않는다.

---

## 5. Bridge

`RealtimeEnvValues`에 `jarvisAPIToken`, `jarvisAPIOrigin`을 추가한다. `OPENAI_API_KEY`는 파일에서 읽더라도 connect에 쓰지 않는다.

connect:

1. Realtime 토글 ON, PCM running (기존)
2. token·origin이 없으면 `.failed("jarvis auth")`
3. `JarvisAPIClient.mintRealtimeClientSecret` 호출
4. 실패면 `.failed("network")` 또는 mint가 401이면 `.failed("jarvis auth")`. adapter.connect는 호출하지 않음
5. 성공하면 adapter Bearer = `value`, 기존처럼 connect → session.update → WAV

기존 실패 정책: Realtime 실패는 route/PCM을 롤백하지 않는다.

---

## 6. 테스트

API: mock `fetch`. 성공 200 필드, 401, OpenAI 오류 503. 로그/에러 문자열에 `ek_` / token이 없음.

Bridge:

- env가 `JARVIS_API_TOKEN` / `JARVIS_API_ORIGIN`을 읽음
- mint 성공 → adapter가 ephemeral Bearer로 connect
- mint 401 → `.failed("jarvis auth")`, adapter connect 0
- mint 네트워크 실패 → `.failed("network")`, PCM running
- 기존: 토글 OFF, adapter 실패, speech_started clearTX, session.update VAD

실 OpenAI·실 CoreAudio 없음.

---

## 7. 실기기

1. `jarvis-api.twms.ai`에 엔드포인트 배포
2. `bridge/.env`에 origin + token. `OPENAI_API_KEY` 없음
3. 앱 재시작, Realtime 토글 ON, 실통화 Active + Connected
4. 한 턴 이상 들림
5. 로그에 secret/token 없음. 드라이버 재설치 없음

---

## 8. 완료 판정

```text
PASS
  - api + bridge 단위 테스트 통과
  - 실통화 Connected, .env OPENAI_API_KEY 없이 한 턴
  - 로그에 OpenAI secret / Jarvis token 없음
  - 드라이버 미변경
  - 키 미커밋

PASS 뒤에 Phase 5 COMPLETE 아님
CP2 (Tool → Agent)는 자동 시작하지 않음
```

---

## 9. 명시적 비범위

- Keychain
- Realtime function call → `/api/agent/message`
- Memory, Approval 전화 UX, Scheduler
- `POST /api/calls`, R2, 녹음
- 주인 takeover (Phase 6)
- 드라이버 수정, 070 / SIP
