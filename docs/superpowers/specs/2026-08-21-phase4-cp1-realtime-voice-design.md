# Phase 4 CHECKPOINT 1 — Realtime 기반 설계

날짜: 2026-08-21  
상태: 구현 COMPLETE — 실기기 1 kHz FINAL PASS (2026-08-22)  
근거: `docs/Jarvis_Call_Bridge_Client_PRD.md` §16–18, §21, Phase 4 완료 기준  
선행: Phase 3 실기기 게이트 PASS (RX, TX 1 kHz, 동시 RX/TX, 연속 2통화, route restore, Active+PCM 중 Work Mode OFF)

이 문서는 CHECKPOINT 1만 정의한다. OpenAI 실연결, barge-in, Agent, 녹음은 여기 없다.

---

## 1. 한 줄 목표

Inject TX를 **링 하나**로 바꾸고, 나중에 Realtime이 꽂힐 adapter·변환·세션 순서를 테스트로 고정한다. 실제 전화에는 AI를 붙이지 않는다.

실기기에서 사람이 확인할 것은 하나다. Active + PCM Running에서 1 kHz가 상대 폰에 1초 동안 깨끗이 들리는지.

---

## 2. 잠근 결정

| 항목 | 결정 |
|---|---|
| TX 경로 | 소비 경로는 링 하나. 1 kHz는 그 링을 채우는 생산자 |
| Realtime 연결 시점 | PCM Running인 Active에서만. Ringing prewarm은 나중 체크포인트 |
| 앱에서 mock 연결 | 하지 않음. 앱 Realtime은 Idle. mock은 테스트 전용 |
| 완료 기준 | 단위/통합 테스트 + 1 kHz 실기기 한 번 |
| Provider 포맷 | 24 kHz / PCM16 / mono (이후 OpenAI Realtime과 동일) |
| HAL 포맷 | 기존 계약 유지: 48 kHz / Float32 / stereo / interleaved |
| 드라이버 | 수정·재설치 없음 |
| 하지 않음 | OpenAI/네트워크, VAD, barge-in, 녹음, Agent, 070/SIP, in-driver 하드웨어 sink |

---

## 3. 아키텍처

```text
상대 목소리
  → Phone.app → Default Output = Capture
  → Bridge RX (AUHAL / Rrxc fallback)
  → [이번 체크포인트 앱에서는 여기까지. 변환기는 테스트만]

1 kHz 버튼 (앱) 또는 mock TX (테스트)
  → 비실시간 생산자가 48 kHz stereo Float32를 TX 링에 씀
  → Inject IOProc이 링만 읽음
  → 링이 비면 디지털 무음 + txUnderrunCount
  → Inject → Default Input → Phone.app → 상대
```

콜백(Inject IOProc) 안에서 하지 않는 것: 톤 사인 계산, 리샘플, Swift 호출, 할당, 파일/네트워크, 로그.

변환 방향 (순수 함수, 테스트만):

```text
RX 테스트: 48k stereo f32 → downmix → 24k → PCM16 mono
TX 테스트: PCM16 mono → 24k f32 → 48k → stereo 복제
```

세션 순서:

```text
route verification PASS → PCM start 성공
  → (테스트) realtime.connect
  → (앱) provider 없음, connect는 no-op

restore / Work Mode OFF / rollback / ownership-loss
  → realtime.disconnect (없으면 no-op)
  → pcm.stop (inject → capture)
  → route restore / device deactivate
```

PCM은 기존과 같이 Ringing에서 열지 않는다. Realtime도 Ringing에서 열지 않는다.

---

## 4. 구성 요소와 파일

### 4.1 TX 링 — C (`JarvisPCMRealtime`)

고침: `bridge/Sources/JarvisPCMRealtime/include/JarvisPCMRealtime.h`  
고침: `bridge/Sources/JarvisPCMRealtime/JarvisPCMRealtime.c`

역할: 48 kHz stereo interleaved Float32의 lock-free 단일 생산자 / 단일 소비자 링.

| API | 의미 |
|---|---|
| `WriteTXFrames` | 비실시간. 넣은 프레임 수를 반환. 가득 차면 일부만 받거나 0. 블로킹 없음 |
| IOProc 소비 | 실시간. 있는 만큼 복사하고 나머지는 0. 한 콜백을 다 채우지 못하면 `txUnderrunCount`를 **1** 올린다 (부족 프레임 수가 아님) |
| `ClearTX` | 링 비움. stop / reset / 이후 barge-in이 같은 함수를 씀 |
| 용량 | 약 200 ms = 9600 프레임. 나중에 Realtime 지연과 맞춤 |

`JarvisPCMInjectIOProc`은 톤을 계산하지 않는다. 링을 읽고, 부족분은 0으로 채운다.

`JarvisPCMRuntimeReset` / `stop` 경로는 `ClearTX`와 톤 상태 초기화를 포함한다.

### 4.2 1 kHz 생산자

고침: `SystemCallAudioPCMController.swift` (`sendTestTone`)  
톤 상태 기계는 C에 유지: idle → queued → playing → idle.

상수(Phase 3와 동일): 1000 Hz, 1.0초(48000 프레임), 진폭 0.1, 양 채널 동일, 위상 0에서 시작, 자동재생 없음. queued/playing 중 재요청은 거부.

사인 계산과 위상은 **생산자(비실시간)** 가 가진다. IOProc은 위상을 모른다.

`sendTestTone` 동작:

1. PCM이 Running이 아니면 기존처럼 ignore.
2. `RequestTone(48000)`이 실패하면 기존처럼 reject.
3. 첫 청크는 동기적으로 링에 쓴다 (최대 용량까지, 약 200 ms). 첫 콜백이 빈 링을 만나지 않게 한다.
4. 남은 프레임은 비실시간 타이머/태스크가 청크로 이어서 쓴다.
5. `completed`는 약속한 48000 프레임이 **링에서 소비된 뒤**다. 생산자가 쓰기만 끝낸 시점이 아니다.

단위 테스트는 사인을 미리 만들어 `WriteTXFrames`한 다음 IOProc을 돌린다. 지금처럼 `RequestTone`만 하고 IOProc이 사인을 만들어 주기를 기대해서는 안 된다.

### 4.3 변환기

새 파일: `bridge/Sources/JarvisCallBridge/Realtime/RealtimeAudioConverter.swift`  
테스트: `bridge/Tests/JarvisCallBridgeTests/RealtimeAudioConverterTests.swift`

순수 함수. CoreAudio 없음. 네트워크 없음.

- Downmix: `(L + R) / 2`
- Upmix: 모노를 L/R에 복제
- 리샘플: 선형 보간. CP1은 라이브러리 추가 없음
- Float32 → PCM16: `[-1, 1]` 클램프 후 `× 32767`
- PCM16 → Float32: `/ 32768`

포맷 상수는 변환기(또는 작은 `RealtimeAudioFormat`)에 둔다. 모델명·API 키는 두지 않는다.

### 4.4 Adapter

새 파일:

- `Realtime/RealtimeVoiceAdapting.swift` — 프로토콜
- `Realtime/MockRealtimeVoiceAdapter.swift` — 테스트용

앱 타깃에 OpenAI 구현을 넣지 않는다. mock은 연결/해제와 변환된 버퍼 입출력만 기록한다.

### 4.5 세션 컨트롤러

새 파일: `Realtime/RealtimeVoiceSessionControlling.swift`  
새 파일: `Realtime/NullRealtimeVoiceSessionController.swift` — 앱 기본값. connect/disconnect 즉시 성공, 부수 효과 없음.

고침: `CallAudioSessionController.swift`

- `pcmController`와 같이 주입한다. 생성 기본값은 `NullRealtimeVoiceSessionController`.
- `startPCMIfNeeded`가 PCM start에 성공한 뒤에만 `realtime.connect(reason:)`. Null이라 앱에서는 no-op.
- 아래 세 곳 모두 `pcmController.stop` **앞**에 `realtime.disconnect(reason:)`  
  - `restore`  
  - `rollback`  
  - ownership-loss
- 순서 테스트는 스파이 세션을 주입한다. mock adapter는 변환/연결 단위 테스트에서만 쓴다. CP1에서 `CallAudioSessionController`가 adapter를 직접 알 필요는 없다.

테스트 기본 생성자가 실제 CoreAudio나 네트워크를 열면 안 된다. 기존 PCM 스파이와 같이 Realtime 스파이를 넣는다.

### 4.6 UI

`ContentView`의 Realtime 줄은 변경하지 않는다. Connected, 키 입력, “Realtime 시작” 버튼은 CP1에 없다. 1 kHz 버튼은 그대로다.

---

## 5. 실패 처리

원칙: **Realtime 실패는 route/PCM을 롤백하지 않는다.** 통화 오디오 소유권과 AI 연결은 다른 실패 모드다.

| 상황 | 동작 |
|---|---|
| 앱, provider 없음 | connect/disconnect는 즉시 성공 no-op |
| 테스트 mock connect 실패 | 로그, Realtime은 미연결. PCM과 route는 유지 |
| TX 링 가득 | `WriteTXFrames`가 받은 개수만 반환. 생산자가 다음에 이어서 씀. IOProc은 기다리지 않음 |
| TX 링 비어 콜백 도착 | 무음. 그 콜백에서 `txUnderrunCount` +1. 크래시 없음 |
| PCM stop / reset | `ClearTX` + 톤 idle. 다음 통화에 이전 톤/오디오가 남지 않음 |
| 잘못된 `AudioBufferList` | 기존처럼 underrun 기록, 크래시 없음 |
| Work Mode OFF / 종료 / ownership-loss | disconnect → PCM stop → restore. disconnect는 idempotent |

변환기 입력 길이가 0이거나 채널이 예상과 다르면 빈 결과를 반환한다. 예외로 흐름을 치지 않는다.

---

## 6. 테스트

기존 `SystemCallAudioPCMControllerComputationTests`의 “IOProc이 사인을 직접 생성”하는 테스트는 링 생산자 모델에 맞게 고친다. Phase 3 불변식(주파수, 진폭, 위상 연속, 종료 후 무음, 재요청 거부, stale replay 없음)은 그대로 증명해야 한다.

추가:

- 링: write → consume 일치, 부분 write, 빈 링 underrun, `ClearTX` 후 무음
- 톤: idle에서 한 번만 성공, queued/playing 중 거부, 소비 후 completed
- 변환: 무음 왕복, 짧은 톤 조각 왕복(에너지가 살아 있는지). 비트 단위 무손실은 요구하지 않음 (리샘플)
- 세션: PCM 시작 전 connect 없음, start 성공 뒤에만 connect, restore/rollback/ownership-loss에서 disconnect가 `pcm.stop`보다 앞섬

실기기:

1. 앱만 재빌드 (드라이버 재설치 없음)
2. Work Mode ON, 실통화 Active, PCM Running
3. Send 1 kHz Test Tone 한 번
4. 상대 폰에서 1초 삐가 끊기지 않고 들리면 PASS

실패 시 링/생산자를 고친다. OpenAI로 넘어가지 않는다.

---

## 7. 완료 판정

```text
PASS
  - 위 단위/통합 테스트 통과
  - 1 kHz 실기기 한 번 PASS
  - 앱 Active 통화에서 Realtime provider 미연결
  - 드라이버 미변경

이 전까지 Phase 4 CHECKPOINT 2 (실통화 speech-to-speech)는 BLOCKED
```

---

## 8. 명시적 비범위

- OpenAI Realtime WebSocket, API 키, Keychain, Jarvis ephemeral credential
- Ringing prewarm
- VAD, barge-in, response cancel, pending speech intent
- STT→LLM→TTS 직렬 파이프라인
- 녹음, R2, Agent/Memory/Tool
- Capture RX shm stale 근본 수정 (Rrxc fallback 유지)
- Continuity ducking 우회
- 070 / SIP / in-driver 하드웨어 sink

---

## 9. 구현 시작 시 기록

구현 계획 작성 전에 하지 않는다. 코드 착수 시:

1. `docs/Call_Bridge_v2_Phase_3_Report.md` 헤더를 Phase 3 COMPLETE로 갱신 (본문 이력은 유지)
2. `docs/Call_Bridge_v2_Phase_4_Report.md`를 만들고 CHECKPOINT 1을 IN PROGRESS로 둔다

에이전트는 이 스펙 승인 없이 구현에 들어가지 않는다.
