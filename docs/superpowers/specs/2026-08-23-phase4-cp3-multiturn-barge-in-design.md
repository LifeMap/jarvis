# Phase 4 CHECKPOINT 3 — 여러 턴 + 상대 끼어들기

날짜: 2026-08-23  
상태: 설계 승인. 구현 전  
브랜치: `phase4-cp3-barge-in`  
근거: `docs/Jarvis_Call_Bridge_Client_PRD.md` Phase 4  
선행: Phase 4 CHECKPOINT 2 FINAL PASS (한 턴 speech-to-speech, 2026-08-22)  
스펙(선행): `docs/superpowers/specs/2026-08-22-phase4-cp2-openai-realtime-design.md`

이 문서는 CHECKPOINT 3만 정의한다. 주인(Jarvis Call Bridge를 켠 사람)의 통화 개입, Jarvis Agent, Phase 7 녹음은 여기 없다.

---

## 1. 한 줄 목표

이미 열려 있는 OpenAI Realtime 세션에서 **한 통화 동안 여러 턴**이 이어지고, **전화 상대**가 AI 말 중에 말하면 AI가 상대 폰에서 즉시 멈춘 뒤 새 말에 답한다.

주인은 끼어들지 않는다. 로컬 마이크 takeover, 개입 버튼, 주인 음성으로 응답을 끊는 경로는 없다.

---

## 2. 잠근 결정

| 항목 | 결정 |
|---|---|
| 여러 턴 | 한 통화, 상대가 두세 번 말하면 AI가 이어서 답함 |
| 상대 끼어들기 | 켬. AI 재생 중 상대가 말하면 생성을 멈추고 로컬 TX를 비움 |
| 주인 개입 | 없음. Phase 6 Human Takeover |
| 턴 경계 | OpenAI `server_vad`. 로컬 에너지 VAD 없음 |
| 다음 답 | `create_response: true` (침묵 후 자동 response) |
| 서버 끊기 | `interrupt_response: true` |
| 로컬 끊기 | `input_audio_buffer.speech_started`(또는 동등 이벤트)에서 adapter TX 큐를 비우고 `ClearTX`. 이미 링에 들어간 AI 오디오가 계속 나가지 않게 |
| 클라이언트 `response.cancel` | 보내지 않음. 서버 `interrupt_response`에 맡김 |
| 연결/토글/인증/포맷/RX 경로 | CP2와 동일. Continuity 탭 RX, `.env` 키, 토글 ON + Active + PCM |
| TX 워터마크 | CP2와 동일 ≈ 200 ms (9600 프레임) |
| 실패 | Realtime 실패는 route/PCM 롤백 없음 |
| 확인 | 실기기 2–3턴 + 끼어들면 상대 폰에서 AI가 바로 끊김. 디버그 WAV |
| 드라이버 | 수정·재설치 없음 |
| Phase 4 | 실기기 PASS 뒤에 COMPLETE. barge-in(상대)은 포함, 주인 개입은 제외하고 PRD 문구를 맞춤 |
| Jarvis | Agent / Memory / ephemeral 키는 Phase 5 |

---

## 3. 아키텍처

PCM 경로(Continuity 탭 → RX 링 → 24 kHz PCM16 → WebSocket → TX 링 → Inject)는 CP2와 같다.

바뀌는 것은 세션 설정과 제어면 인터럽트뿐이다.

```text
상대 말 → Continuity 탭 → RX → input_audio_buffer.append
  → (침묵) server_vad → 자동 response → audio.delta → TX 링 → Inject → 상대

AI 재생 중 상대가 다시 말함
  → speech_started
  → 서버: interrupt_response가 현재 response 중단
  → 앱: txQueue 비움 + ClearTX
  → (침묵) 새 response → 상대
```

IOProc / AUHAL 콜백 안에서 하지 않는 것: VAD, JSON, ClearTX 호출을 콜백에서 직접. ClearTX는 CP1과 같이 제어면(펌프/이벤트 ingest가 메인 액터에서 호출).

`RealtimePCMBuffering`에 `clearTX()`를 추가한다. 구현은 기존 `JarvisPCMRuntimeClearTX`. `clearRX`처럼 disconnect 때 호출해도 된다. 끼어들기 때는 RX는 비우지 않는다 — 상대 말이 들어오는 중이다.

---

## 4. session.update

CP2 바디를 유지하고 `session.audio.input.turn_detection`에 아래를 **명시**한다. 빠지면 OpenAI 기본이 끼어들기를 끄거나 켤 수 있다. 서버가 최상위 `session.turn_detection`만 받으면 같은 체크포인트에서 그 키로 옮긴다. 두 경로를 동시에 넣지 않는다.

```text
turn_detection.type = server_vad
create_response = true
interrupt_response = true
```

`silence_duration_ms` / `threshold` / `prefix_padding_ms`는 기본값. CP3에서 튜닝하지 않는다. 실기기에서 턴이 너무 빠르거나 느리면 다음 체크포인트에서만 연다.

instructions, 모델, PCM 포맷, 목소리는 CP2와 동일.

---

## 5. 이벤트와 로컬 클리어

adapter가 파싱하는 서버 이벤트:

| 이벤트 | 동작 |
|---|---|
| `response.output_audio.delta` / `response.audio.delta` / `session.output_audio.delta` | CP2와 같이 TX 큐에 추가 |
| `input_audio_buffer.speech_started` | 끼어들기 신호. TX 큐를 비움. 세션에 `onRemoteSpeechStarted`를 알려 ClearTX |
| 그 외 | 무시. 로그에 raw PCM/전사 없음 |

`speech_started`가 응답 중이 아닐 때 와도 ClearTX는 안전하다(빈 링 no-op). 그래서 “응답 중인가” 상태 머신을 필수로 두지 않는다. 선택적으로 in-flight response id를  ent아도 되지만 CP3 성공 조건이 아니다.

1 kHz 톤과 Realtime이 같은 TX 링을 쓴다. 끼어들기 ClearTX는 톤도 지운다. CP3에서 막지 않음. 실기기 끼어들기 테스트 중에는 톤을 누르지 않는다.

---

## 6. 테스트

가짜 transport / PCM 스파이만. 실 OpenAI·실 CoreAudio 없음.

- `session.update` JSON에 `server_vad`, `create_response == true`, `interrupt_response == true`
- 오디오 delta 두 번(첫 응답 + 둘째 응답)을 ingest하면 `pollTX`가 둘 다 꺼냄 (여러 턴 큐)
- `speech_started` 후 `pollTX`는 그 전에 쌓인 delta를 돌려주지 않음
- 세션 펌프: `speech_started` 한 번에 PCM `clearTX` 1회. `clearRX` 0회. PCM `isRunning` 유지
- 기존 CP2: 토글 OFF는 disconnect만, 실패는 route 롤백 없음 — 회귀 유지

---

## 7. 실기기

1. 앱 재시작 후 Realtime 토글 ON
2. 실통화 Active + PCM Running + Connected
3. 상대가 한 마디 → AI 답 (턴 1)
4. 답이 끝난 뒤 상대가 또 한 마디 → AI가 다시 답 (턴 2). 가능하면 턴 3
5. AI가 말하는 동안 상대가 끼어듦 → 상대 폰에서 AI가 즉시 끊기고, 새 말에 답함
6. `~/Documents` RX/TX WAV에 답이 두 번 이상 에너지로 보임
7. 종료 후 route restore. 드라이버 재설치 없음

주인 마이크/개입 버튼은 확인하지 않는다.

---

## 8. 완료 판정

```text
PASS
  - 단위 테스트 통과
  - 실기기 2–3턴
  - 실기기 상대 끼어들기 (폰에서 AI 즉시 정지)
  - 디버그 WAV로 여러 턴 확인
  - 주인 개입 UI/경로 없음
  - 드라이버 미변경
  - 키 미커밋

PASS 뒤에 Phase 4 = COMPLETE
주인 Human Takeover는 Phase 6으로 남긴다
에이전트는 PASS 뒤에 Phase 5를 자동으로 시작하지 않는다
```

---

## 9. 명시적 비범위

- 주인(Jarvis를 켠 사람)이 통화에 끼어들어 AI를 끊기
- Mac Human Takeover UI, 로컬 마이크를 RX에 섞기
- 로컬 에너지 VAD, 클라이언트 `response.cancel`
- `silence_duration_ms` 튜닝
- Cloudflare Jarvis API, Agent, Memory, Tool, Approval, ephemeral 키
- Phase 7 녹음, merged.m4a, R2
- 드라이버 수정, Capture WriteMix 복구, 하드웨어 sink
- 070 / SIP
