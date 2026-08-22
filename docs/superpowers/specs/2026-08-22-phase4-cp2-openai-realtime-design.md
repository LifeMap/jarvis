# Phase 4 CHECKPOINT 2 — OpenAI Realtime 실연결 설계

날짜: 2026-08-22  
상태: **FINAL PASS** (실기기 한 턴 2026-08-22 23:57). 보고: `docs/Call_Bridge_v2_Phase_4_Report.md`  
브랜치: `phase4-cp2-openai-realtime`  
근거: `docs/Jarvis_Call_Bridge_Client_PRD.md` §16–18, §21, Phase 4  
선행: Phase 4 CHECKPOINT 1 FINAL PASS (1 kHz 실기기, 2026-08-22)  
스펙(선행): `docs/superpowers/specs/2026-08-21-phase4-cp1-realtime-voice-design.md`

이 문서는 CHECKPOINT 2만 정의한다. Jarvis Agent, ephemeral 키, barge-in, Phase 7 녹음은 여기 없다.

---

## 1. 한 줄 목표

Active + PCM Running인 실통화에서, 토글이 켜져 있을 때만 OpenAI Realtime에 붙어 **한 턴** speech-to-speech를 확인한다.

실기기에서 사람이 확인할 것은 하나다. 상대 말이 AI로 들어가고, AI 답이 TX로 상대 폰에 들리는지. `~/Documents`의 RX/TX 디버그 WAV로 한 턴을 같이 본다.

---

## 2. 잠근 결정

| 항목 | 결정 |
|---|---|
| Provider | OpenAI Realtime. 앱 안 Swift `URLSession` WebSocket (접근 A) |
| 모델 | 코드에 박지 않음. 기본값 `gpt-realtime-2.1-mini`. `.env`의 `OPENAI_REALTIME_MODEL`이 있으면 그 값 |
| 인증 | `bridge/.env`의 `OPENAI_API_KEY`. Git에 넣지 않음. Keychain·Jarvis ephemeral 없음 |
| 연결 시점 | Realtime 토글 ON **그리고** Active + PCM Running. Ringing에서 열지 않음 |
| 토글 | 기존 Realtime 줄 옆 ON/OFF. 앱을 켜면 항상 꺼짐 |
| 언어 | 한국어 기본 시스템 프롬프트 + 상대가 쓰는 언어로 맞춰 대답. 목소리는 OpenAI 기본값 |
| 포맷 | CP1과 동일. Provider 24 kHz / PCM16 / mono. HAL 48 kHz / Float32 / stereo / interleaved |
| TX 링 | 용량은 CP1 실기기 수정 그대로 48000 프레임(1 s). Realtime은 **약 200 ms(9600 프레임) 워터마크**만 유지. 1초를 미리 채우지 않음 |
| 1 kHz | 그대로 둠. 같은 TX 링. Realtime 재생 중 톤을 눌러 섞이는 것은 CP2에서 막지 않음 |
| 실패 | Realtime 실패는 route/PCM을 롤백하지 않음. 자동 재연결 없음 |
| 확인 | 한 턴이면 충분. 디버그 WAV 두 개(RX/TX). Phase 7 제품 녹음 아님 |
| 드라이버 | 수정·재설치 없음 |
| Jarvis | Cloudflare Worker / Agent / 도구 / 메모리 / ephemeral 키는 Phase 5 |

---

## 3. 아키텍처

```text
상대
  → Continuity (avconferenced) → 기존 mute 탭 aggregate (input-only AUHAL)
  → RX 소비 링 (제어면 Read)
  → 변환 (24 kHz mono PCM16)
  → OpenAI Realtime WebSocket
  → 변환 (48 kHz stereo f32)
  → TX 링 (워터마크 ≈ 200 ms)
  → Inject IOProc (링만 읽음)
  → Phone.app → 상대
```

실기기 개정 (2026-08-22): Active 구간 Capture WriteMix는 벨/연결음 뒤에 디지털 무음이었다 (`captureWriteMixNonZero` 고정, peak 0). Phone 기본 출력 경로로는 상대 음성이 오지 않아, 이미 켜 둔 `avconferenced` 뮤트 탭을 RX로 읽는다. 뮤트는 유지. 드라이버 변경 없음. 탭 AUHAL 실패 시에만 WriteMix/Rrxc 폴백.

IOProc 안에서 하지 않는 것: 리샘플, Swift 호출, 할당, 파일, 네트워크, 로그. CP1과 같다.

세션 순서 (CP1 유지, 토글만 추가):

```text
토글 ON + route verification PASS + PCM start 성공
  → .env에서 키 읽기
  → realtime.connect
  → RX 펌프 / TX 펌프 / 디버그 WAV 시작

토글이 꺼진 채 PCM start
  → connect 호출은 해도 네트워크 없음 (Idle)

통화 중 토글 ON (이미 PCM Running)
  → 그때 connect. 다음 통화까지 기다리지 않음

토글 OFF / 통화 종료 / Work Mode OFF / rollback / ownership-loss
  → realtime.disconnect (WAV 닫기, 없으면 no-op)
  → 그다음 pcm.stop
  → 그다음 route restore
```

PCM과 Realtime은 Ringing에서 열지 않는다.

`.app` 경로: `bridge/.build/Jarvis Call Bridge.app`  
`.env` 경로: 번들 부모의 부모 = `bridge/.env`.

키 탐색 순서:

1. 이미 있는 프로세스 환경변수 `OPENAI_API_KEY` (테스트·스크립트)
2. `bridge/.env` 파일 (실행 파일 기준으로 위 경로)
3. 둘 다 없으면 연결하지 않음

앱 번들, `Info.plist`, 소스에 키를 넣지 않는다.

---

## 4. 구성 요소와 파일

### 4.1 `.env`

새 파일(커밋): `bridge/.env.example`

```text
OPENAI_API_KEY=
OPENAI_REALTIME_MODEL=gpt-realtime-2.1-mini
```

새 파일(무시): `bridge/.env` — 같은 키, 실제 값만.

고침: 저장소 `.gitignore`에 `bridge/.env`를 넣는다.

로더: `bridge/Sources/JarvisCallBridge/Realtime/RealtimeEnvFile.swift`  
테스트: `bridge/Tests/JarvisCallBridgeTests/RealtimeEnvFileTests.swift`

- `KEY=value` 줄만 읽는다. `#` 주석, 빈 줄 허용.
- 값 양끝 공백과 따옴표 한 겹은 벗긴다.
- 파일 없음 / 키 없음 / 빈 값 → 키 없음으로 취급. 예외를 던지지 않는다.
- 테스트는 임시 파일만 쓴다. 실제 키를 픽스처에 넣지 않는다.

### 4.2 RX 소비 링

고침: `bridge/Sources/JarvisPCMRealtime/include/JarvisPCMRealtime.h`  
고침: `bridge/Sources/JarvisPCMRealtime/JarvisPCMRealtime.c`

Capture 쪽은 지금 메트릭만 올린다. Realtime이 순서대로 읽으려면 제어면 링이 필요하다.

| API | 의미 |
|---|---|
| IOProc / `PublishRXFrames` | 48 kHz stereo f32를 RX 링에 넣음. 블로킹 없음. 가득이면 **새 프레임을 버리고** `rxOverflowCount`를 올린다. 콜백은 기다리지 않음 |
| `ReadRXFrames` | 비실시간. 있는 만큼 복사하고 개수를 반환. 빈 링은 0. 이것이 실패가 아님 |
| `ClearRX` | `ClearTX`와 같이 stop / reset / disconnect에서 비움 |

용량은 TX와 같이 48000 프레임이어도 된다. 펌프는 모이지 않게 자주 읽는다.

덮어쓰기 정책을 하나로 고정한다: **가득이면 새 프레임을 버리고 온 개수를 센다** (`rxOverflowCount`). 통화 상대의 과거를 되감아 재생하지 않는다.

### 4.3 변환기

기존 `RealtimeAudioConverter` / `RealtimeAudioFormat`을 그대로 쓴다. 새 포맷 없음.

펌프(비실시간)만 변환기를 호출한다.

### 4.4 OpenAI adapter

새 파일: `bridge/Sources/JarvisCallBridge/Realtime/OpenAIRealtimeVoiceAdapter.swift`

기존 `RealtimeVoiceAdapting`을 구현한다.

```text
connect() async -> Bool
disconnect() async
sendRX(_ pcm16Mono24k: [Int16])
pollTX() -> [Int16]
```

- `connect`는 WebSocket을 열고 세션을 준비한다. 실패하면 `false`.
- `sendRX`는 연결된 뒤에만 보낸다. 아니면 버린다.
- `pollTX`는 받은 PCM16을 반환한다. 없으면 빈 배열. 블로킹 없음.
- mock(`MockRealtimeVoiceAdapter`)은 테스트에 남긴다. 앱 기본 경로는 OpenAI 구현이다.

세션 지시문(고정):

```text
당신은 전화로 통화 중인 한국어 비서입니다.
상대가 쓰는 언어로 맞춰, 짧게 자연스럽게 대답하세요.
```

도구 호출 없음. barge-in / response cancel 없음.

### 4.5 세션 컨트롤러

새 파일: `bridge/Sources/JarvisCallBridge/Realtime/OpenAIRealtimeVoiceSessionController.swift`

앱 기본값을 `NullRealtimeVoiceSessionController`에서 이 구현으로 바꾼다.  
테스트 기본 생성자는 계속 Null/스파이. 네트워크를 열면 안 된다.

역할:

- 토글과 PCM 상태를 보고 실제로 붙을지 정한다.
- 붙으면 RX 펌프(ReadRX → 변환 → `sendRX`)와 TX 펌프(`pollTX` → 변환 → `WriteTXFrames`, 워터마크 ≈ 200 ms)를 켠다.
- 디버그 WAV를 연다.
- `disconnect`는 펌프 정지, WAV 닫기, adapter disconnect, `ClearRX`. **`ClearTX`는 호출하지 않는다** — 같은 링의 1 kHz와 이미 넣은 AI 잔여를 구분할 수 없다. 톤 상태 기계는 건드리지 않는다.

`CallAudioSessionController`의 순서(PCM start 뒤 `connect`, restore/rollback/ownership-loss에서 `disconnect`가 `pcm.stop`보다 앞)는 바꾸지 않는다.

토글 ON이 통화 중간에 오면 ViewModel이 `connect(reason:)`를 한 번 더 호출한다. 이미 연결이면 idempotent.

### 4.6 디버그 WAV

새 파일: `bridge/Sources/JarvisCallBridge/Realtime/RealtimeDebugWAVWriter.swift`  
테스트: `bridge/Tests/JarvisCallBridgeTests/RealtimeDebugWAVWriterTests.swift`

Phase 7 제품 녹음이 아니다. 세션이 열려 있는 동안만 쓴다.

| 파일 | 내용 |
|---|---|
| `~/Documents/jarvis-call-bridge-rx-YYYYMMDD-HHmmss.wav` | Provider로 보낸 24 kHz mono PCM16 |
| `~/Documents/jarvis-call-bridge-tx-YYYYMMDD-HHmmss.wav` | Provider에서 받은 24 kHz mono PCM16 |

표준 PCM WAV 헤더. `disconnect`에서 헤더 길이를 고치고 닫는다. 크래시해도 통화 경로는 유지한다.

### 4.7 UI

고침: `ContentView.swift` Realtime 줄.  
고침: `BridgeViewModel` (토글·상태 게시).

| 표시 | 의미 |
|---|---|
| `Idle` | 토글 꺼짐. 네트워크 없음 |
| `Armed` | 토글 켜짐. 아직 Active+PCM이 아님 |
| `Connecting` | 연결 시도 |
| `Connected` | 붙음 |
| `Failed` | 실패. 짧은 이유 (키 없음, 네트워크 등) |

토글 OFF는 항상 `Idle`. 연결이 끊기면 토글이 켜져 있으면 `Armed`, 꺼져 있으면 `Idle`.

키·토큰·`.env` 원문을 로그와 UI에 쓰지 않는다.

---

## 5. 실패 처리

원칙: **Realtime 실패는 route/PCM을 롤백하지 않는다.**

| 상황 | 동작 |
|---|---|
| `.env` 없음 / 키 없음 | 연결하지 않음. `Failed`. PCM·route 유지 |
| WebSocket/세션 실패 | `Failed`. 자동 재연결 없음. PCM·route 유지 |
| 통화 중 토글 OFF | 연결만 끊음. PCM·route 유지 |
| 통화 종료 / Work Mode OFF / rollback / ownership-loss | disconnect → pcm.stop → restore. disconnect는 idempotent |
| RX 링 가득 | 새 프레임 버림 + overflow 카운트. 콜백은 계속 |
| RX 링 빔 (펌프) | 이번 주기에 보내지 않음. 오류 아님 |
| TX 링 가득 | `WriteTXFrames`가 받은 만큼만. 나머지는 다음 펌프 |
| TX 링 빔 + Realtime이 아직 말 안 함 | 무음. **underrun으로 치지 않음** (CP1: 톤 queued/playing일 때만 underrun) |
| WAV 쓰기 실패 | 로그. 세션은 유지 |
| 1 kHz와 Realtime 동시 | 같은 링에 섞일 수 있음. CP2에서 거부하지 않음 |

---

## 6. 테스트

앱 타깃 테스트는 실제 OpenAI에 붙지 않는다.

유지:

- 변환기
- mock adapter
- 세션 순서: PCM start 전 connect 없음, start 뒤 connect, disconnect가 `pcm.stop`보다 앞

추가:

- 토글 꺼짐: PCM start 뒤에도 adapter `connect` 없음
- 토글 켜짐 + PCM Running: adapter `connect` 한 번
- 통화 중 토글 ON: 이미 Running이면 connect
- 통화 중 토글 OFF: disconnect만. pcm.stop / route rollback 없음
- adapter `connect == false`: 세션 `Failed`. route/PCM 스파이 불변
- `.env` 로더: 없는 파일, 빈 키, 주석, 따옴표 값
- WAV 라이터: 짧은 PCM16을 쓰고 헤더가 맞는지
- RX `ReadRXFrames`: write → read 일치, 빈 링 0, overflow 시 새 데이터 버림

실기기:

1. `bridge/.env`에 키를 넣는다. 앱만 재빌드 (드라이버 재설치 없음)
2. 앱 시작 시 Realtime은 꺼짐
3. 토글 ON → `Armed`
4. 실통화 Active, PCM Running → `Connected`
5. 상대가 한 마디 하면 AI 답이 상대 폰에 들리면 PASS
6. `~/Documents`에 rx/tx WAV가 생기고, 한 턴 에너지가 보이면 확인 완료
7. 토글 OFF → 연결만 끊김. 통화 오디오는 유지

한 턴이면 충분. 끼어들기는 보지 않음.

---

## 7. 완료 판정

```text
PASS
  - 위 단위/통합 테스트 통과
  - 실기기 한 턴 speech-to-speech PASS
  - 디버그 WAV 두 개로 한 턴 확인
  - Realtime 실패가 route/PCM을 롤백하지 않음
  - 앱을 다시 켜면 토글 꺼짐
  - 드라이버 미변경
  - 키 미커밋

이 전까지 Phase 5 (Jarvis Agent / ephemeral 키)와 barge-in은 BLOCKED
에이전트는 CHECKPOINT 2 PASS 뒤에 다음 체크포인트를 자동으로 시작하지 않는다
```

실기기 한 턴 PASS 증거: 로그 `jarvis-call-bridge-log-20260822-235804.txt`, RX/TX WAV `…-235749.wav`. `rxSource=continuity-tap`, TX WAV 8.1 s 에너지, `txUnderrunCount=0`. 상세는 Phase 4 리포트.

---

## 8. 명시적 비범위

- Cloudflare Jarvis API, Agent, Memory, Tool, Approval
- Jarvis ephemeral Realtime credential (PRD §21 — Phase 5)
- 음성 전체를 Worker로 프록시
- STT→LLM→TTS 직렬 파이프라인
- VAD, barge-in, response cancel, pending speech intent
- Phase 7 통화 녹음, merged.m4a, R2
- Ringing prewarm
- Keychain
- 모델명 하드코딩
- 드라이버 수정, Capture RX shm 근본 수정, Continuity ducking 우회
- 070 / SIP / in-driver 하드웨어 sink

---

## 9. 구현 시작 시 기록

구현 계획 작성 전에 코드를 치지 않는다. 코드 착수 시:

1. `docs/Call_Bridge_v2_Phase_4_Report.md` 헤더에서 CHECKPOINT 2를 IN PROGRESS로 바꾼다
2. 본 스펙 경로를 리포트에 적는다

에이전트는 이 스펙 승인 없이 구현에 들어가지 않는다.
