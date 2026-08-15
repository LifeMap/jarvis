# Jarvis Call Bridge Client PRD

## 1. 문서 개요

- 프로젝트명: Jarvis
- 모듈명: Call Bridge Client
- 문서 버전: **v2.1**
- 작성일: 2026-08-15
- 대상 플랫폼: **macOS 26 이상**
- 기본 통화 Host: **macOS Phone.app**
- 개발 언어: **Swift**
- UI Framework: **SwiftUI**
- 개발 위치: **`bridge/`**
- 대상 사용자: **개인용 단일 사용자**
- 핵심 사용 목적: **업무 중 사용자가 직접 전화를 받기 어려울 때 Jarvis가 iPhone 기존 번호의 착신 통화를 대신 받아 용건을 파악하고 필요한 정보를 처리한다.**
- SaaS / Multi-tenant / 과금 기능: 제외

---

# 2. v2.0 재설계 배경

v1.x에서는 다음 구조를 검증했다.

```text
RX
Phone.app
→ ScreenCaptureKit
→ Call Bridge

TX
Call Bridge
→ Shared Memory
→ Jarvis Virtual Mic
→ Phone.app
```

실기기 테스트 과정에서 다음 사실을 확인했다.

1. iPhone의 Calls on Other Devices / Continuity를 통해 macOS Phone.app에서 실제 셀룰러 전화를 수신할 수 있다.
2. macOS에서 직접 사용할 수 있는 native CallKit call-state API를 전제로 할 수 없다.
3. Accessibility를 이용한 Phone.app 수신 UI 제어는 실사용 가능한 후보이다.
4. v1의 `Start Test`를 착신 전에 활성화하면 Mac의 착신 표시 자체가 방해되는 문제가 발생했다.
5. 따라서 **대기 상태에서 Phone.app의 audio route 또는 capture session을 건드리는 구조는 부적합하다.**
6. AITakeCall 실기기 분석에서 통화 중 다음 두 CoreAudio virtual device가 실제 활성화되는 것을 확인했다.

```text
AI Take Call Capture
- Default Output Device
- Input 2ch
- Output 2ch
- 48kHz
- Virtual

AI Take Call Inject
- Default Input Device
- Input 2ch
- Output 2ch
- 48kHz
- Virtual
```

7. AITakeCall은 자체 CoreAudio HAL AudioServerPlugIn을 사용하고, Accessibility로 착신 전화를 자동 수신하며, 통화 중 Capture/Inject 장치를 이용해 RX/TX를 처리하는 구조로 관찰됐다.
8. AITakeCall 역시 iPhone Wi-Fi를 끄면 Mac에서 착신 연결이 되지 않았다.
9. 따라서 **Continuity의 근접성/Wi-Fi 제약은 존재하지만, 본 프로젝트의 "업무 중 개인용 전화비서" 용도에서는 수용한다.**

v2.0은 위 실기기 검증 결과를 기반으로 기존 오디오 구조를 폐기하고 다시 설계한다.

---

# 3. v2.0 핵심 결정

## 3.1 폐기하는 구조

다음은 v2의 주력 구조에서 사용하지 않는다.

```text
ScreenCaptureKit 기반 Phone.app RX
단일 Jarvis Virtual Mic
POSIX shared memory 기반 PCM 전달
/jarvis.cbridge.vmic
Start Test 기반 전체 기능 일괄 활성화
착신 대기 중 Phone.app audio capture 활성화
```

기존 코드는 Git history/tag에 보존하며 v2 production path에는 포함하지 않는다.

## 3.2 신규 구조

```text
Accessibility Call Control
+
Dual HAL Loopback Devices
  - Jarvis Call Capture
  - Jarvis Call Inject
+
CoreAudio Direct I/O
+
Realtime Voice
+
Existing Jarvis API / Agent
```

## 3.3 가장 중요한 운영 원칙

```text
ARMED 상태에서는
Phone.app의 오디오 라우팅을 변경하지 않는다.
오디오 캡처를 시작하지 않는다.
Realtime 세션을 유지하지 않는다.
```

즉 **업무 모드가 켜져 있어도 정상적인 macOS/iPhone 착신 동작을 방해하지 않아야 한다.**

---

# 4. 제품 목표

Jarvis Call Bridge Client의 v2 목표는 다음과 같다.

1. 사용자의 기존 iPhone 셀룰러 번호를 그대로 사용한다.
2. 업무 모드 ON 상태에서 Mac의 Phone.app 착신을 감지한다.
3. 설정된 지연시간 후 Jarvis가 전화를 자동 수신한다.
4. 실제 Caller 음성(RX)을 별도 audio path로 확보한다.
5. Jarvis AI 음성(TX)을 실제 Caller에게 전달한다.
6. RX/TX를 논리적으로 분리한다.
7. Realtime speech-to-speech 대화를 제공한다.
8. Caller가 Jarvis 발화 중 말하면 Jarvis가 즉시 멈춘다.
9. Jarvis의 기존 Memory / Tools / Approval / Scheduler를 재사용한다.
10. 필요 시 사용자가 통화를 직접 takeover 할 수 있다.
11. 통화 종료 후 모든 audio route를 원상복구한다.
12. 후속 Phase에서 RX/TX/merged 녹음, transcript, summary를 저장한다.
13. 최종적으로 서명/notarization 가능한 `.app`과 `.dmg` 배포 구조를 만든다.

---

# 5. 사용자 시나리오

## 5.1 업무 모드 OFF

```text
Caller
→ iPhone
→ iPhone / Mac 정상 착신
→ 사용자가 직접 수신
```

Jarvis Call Bridge는 전화에 개입하지 않는다.

## 5.2 업무 모드 ON

```text
Caller
→ iPhone Cellular
→ Apple Continuity
→ macOS Phone.app
→ Jarvis Call Bridge가 Ringing 감지
→ Jarvis 자동 수신
→ AI가 Caller와 대화
→ 용건 파악 / 필요한 Tool 사용
→ 통화 종료
→ 상태 및 오디오 route 원상복구
```

## 5.3 Human Takeover

Human Takeover는 두 가지 모드로 구분한다.

### A. Mac Takeover — 녹음 계속

```text
AI 통화 중
→ 사용자가 "Mac에서 내가 통화하기" 선택
→ AI TX 즉시 중단
→ 미재생 AI TX buffer clear
→ Realtime session pause/end
→ Capture / Inject audio path 유지
→ Recording 유지
→ Caller RX를 사용자 Mac 출력 장치로 전달
→ 사용자 Mac 입력 장치를 Inject TX source로 전환
→ 사용자가 동일 통화를 직접 이어감
→ 실제 통화 종료 시 Recording finalize + route restore
```

이 모드에서는 **AI만 통화에서 빠지고 Bridge와 녹음은 계속 유지**한다.

통화 전체의 논리적 stream은 다음과 같다.

```text
RX
= 통화 전체 Caller 음성

TX
= AI 구간에서는 Jarvis AI 음성
+ Human Takeover 이후에는 사용자 음성
```

### B. iPhone Takeover — Apple Handoff

```text
AI 통화 중
→ 사용자가 iPhone에서 현재 통화를 이어받음
→ Apple Continuity / Handoff로 통화 endpoint가 Mac → iPhone으로 이동
→ AI TX 즉시 중단
→ Realtime session 종료
→ Mac Bridge recording finalize
→ Bridge audio route restore
→ 사용자가 iPhone으로 직접 통화 계속
```

iPhone Takeover는 Apple이 제공하는 사용자 주도 Handoff 동작을 사용한다.

초기 버전에서는 Bridge가 private API나 UI automation으로 iPhone Handoff를 강제하지 않는다.

통화가 iPhone으로 넘어간 이후에는 Mac이 더 이상 통화 audio endpoint가 아닐 수 있으므로 **Bridge의 녹음 지속을 보장하지 않는다.**

따라서:

```text
Mac Takeover
→ AI 종료
→ Bridge 유지
→ Recording 계속

iPhone Takeover
→ AI 종료
→ Bridge 통화 media 종료
→ Recording finalize
→ iPhone에서 통화 계속
```

---

# 6. 시스템 아키텍처

```text
                         Cellular
Caller  ←────────────────────────────────→  iPhone
                                                │
                                                │
                                      Calls on Other Devices
                                           / Continuity
                                                │
                                                ▼
                                      macOS 26+ Phone.app
                                         │            ▲
                                      RX │            │ TX
                                         │            │
                           ┌─────────────▼──┐      ┌──▼──────────────┐
                           │ Jarvis Call    │      │ Jarvis Call     │
                           │ Capture        │      │ Inject          │
                           │ HAL Device     │      │ HAL Device      │
                           └──────┬─────────┘      └────────▲────────┘
                                  │                         │
                                  ▼                         │
                         ┌────────────────────────────────────────┐
                         │       Jarvis Call Bridge.app           │
                         │                                        │
                         │  Call Lifecycle / Accessibility        │
                         │  CoreAudio RX/TX                       │
                         │  Audio Conversion / Buffering          │
                         │  Barge-in                              │
                         │  Realtime Voice Adapter                │
                         │  Jarvis API Adapter                    │
                         └──────────────────┬─────────────────────┘
                                            │
                           ┌────────────────┴───────────────┐
                           │                                │
                           ▼                                ▼
                  Realtime Voice Layer               Jarvis API / Agent
                                                      - Memory
                                                      - Tools
                                                      - Approval
                                                      - Scheduler
                                                      - Agent State
```

통화 종료 후 후속 Phase:

```text
Call Bridge
├─ rx.m4a
├─ tx.m4a
└─ merged.m4a
      │
      ├─→ Cloudflare R2
      └─→ Jarvis Call API
             ↓
      Durable Object SQLite
```

---

# 7. 기본 원칙

## 7.1 Mac은 Bridge

Mac에서 Local LLM을 실행하지 않는다.

```text
Mac
= Call control
+ Audio routing
+ Audio conversion
+ Recording
+ Realtime transport
+ Jarvis connectivity

Cloud / Realtime Provider
= Voice AI inference
```

## 7.2 1 User = 1 Mac = 1 Bridge

v2 초기 범위:

```text
사용자 1명
iPhone 1대
Mac 1대
Call Bridge 1개
```

지원하지 않음:

- 여러 사용자 동시 처리
- 여러 Apple Account
- 여러 iPhone 동시 처리
- Mac 한 대에서 여러 Bridge instance
- Multi-tenant host

## 7.3 기존 번호 유지

사용자의 현재 iPhone 셀룰러 번호를 그대로 사용한다.

초기 범위에서 사용하지 않음:

- Twilio
- SIP
- BYOC
- 070 번호
- 별도 VoIP 번호

## 7.4 Continuity 제약 수용

본 v2는 개인 업무용으로 다음 조건을 수용한다.

```text
iPhone과 Mac이 Continuity 통화를 사용할 수 있는 상태
+
iPhone Wi-Fi 활성화
+
Apple의 Calls on Other Devices 조건 충족
```

사용자가 iPhone을 들고 외출한 상태에서 집의 Mac이 always-on 전화비서가 되는 것은 v2 목표가 아니다.

## 7.5 Public / Maintainable Path 우선

우선 사용:

- Core Audio
- AudioServerPlugIn
- Accessibility API
- AVFoundation / AVAudioEngine
- Swift / SwiftUI
- URLSession / WebSocket
- Keychain

기본 구조에서 사용하지 않음:

- binary hooking
- process injection
- private framework 강제 의존
- 임의 binary patching

---

# 8. Call Lifecycle 상태 머신

v2는 명시적인 상태 머신으로 동작한다.

AI participation lifecycle, call lifecycle, recording lifecycle을 서로 분리한다.

```text
DISABLED
    │
    │ Work Mode ON
    ▼
ARMED
    │
    │ Incoming call detected
    ▼
RINGING
    │
    ▼
PREPARING
    │
    ├─ Original audio route snapshot
    ├─ Realtime prewarm
    ├─ Audio devices prepare
    └─ Required validation
    │
    ▼
ANSWERING
    │
    ▼
ACTIVE_AI
    │
    ├──────── Mac Takeover ────────→ ACTIVE_HUMAN_MAC
    │                                  │
    │                                  └── Call End → RESTORING
    │
    ├──────── iPhone Handoff ──────→ HANDOFF_TO_IPHONE
    │                                  │
    │                                  ├─ Recording finalize
    │                                  └─ Bridge media release
    │                                           │
    │                                           ▼
    │                                       RESTORING
    │
    └──────── Call End ────────────→ RESTORING
                                         │
                                         ▼
                                       ARMED
```

상태 의미:

```text
ACTIVE_AI
- Capture active
- Inject active
- Recording active (Recording 기능이 활성화된 Phase 이후)
- Realtime active
- TX source = AI

ACTIVE_HUMAN_MAC
- Capture active
- Inject active
- Recording active
- Realtime inactive
- RX sink = 사용자 Mac 출력 장치
- TX source = 사용자 Mac 입력 장치

HANDOFF_TO_IPHONE
- AI inactive
- Realtime inactive
- Mac recording finalize
- Mac call media 종료 감지
- iPhone에서 통화 계속
```

오류 시:

```text
ANY STATE
→ ERROR
→ RESTORING
→ ARMED 또는 DISABLED
```

`RESTORING`은 반드시 idempotent하게 구현한다.

---

# 9. ARMED 상태 요구사항

ARMED는 v2의 가장 중요한 상태이다.

다음만 활성화한다.

```text
Phone.app 존재 확인
Accessibility authorization 상태 확인
Incoming-call UI observation
필요 최소 lifecycle observer
Jarvis API connectivity health
```

다음은 활성화하지 않는다.

```text
Audio Capture
Default Input 변경
Default Output 변경
Virtual Device active routing
Realtime audio session
Recording
ScreenCaptureKit
```

### Acceptance

Bridge가 ARMED 상태인 채로 최소 10회 연속 실제 착신 테스트를 수행했을 때:

- Phone.app 수신 알림이 모두 정상 표시되어야 한다.
- Bridge 때문에 착신이 사라지거나 지연되는 현상이 없어야 한다.
- Work Mode OFF와 비교해 native incoming behavior가 망가지지 않아야 한다.

---

# 10. Call Detection / Control

## 10.1 기본 방식

native macOS CallKit call-state API를 전제로 하지 않는다.

Primary:

```text
Accessibility API
→ Phone.app / incoming call notification UI observation
```

목표 상태:

```text
Idle
Ringing
Answering
Active
Ended
Unknown
```

## 10.2 자동 수신

Ringing이 확인되면 사용자 설정에 따라:

```text
즉시
1초 후
3초 후
5초 후
```

등의 delay를 적용할 수 있다.

자동 수신은 Accessibility를 이용해 실제 수신 UI의 `Answer` 동작을 수행한다.

## 10.3 안전 원칙

- Accessibility anchor가 명확하지 않으면 자동 클릭하지 않는다.
- 전화번호/Caller 정보가 불명확해도 임의의 다른 UI element를 누르지 않는다.
- auto-answer 실패 시 native call UI를 그대로 유지한다.
- Bridge 오류가 native Phone.app 수신 자체를 종료시키면 안 된다.

## 10.4 Fallback

Accessibility 기반 자동 수신이 실패하면:

```text
Manual Answer Mode
```

로 전환할 수 있다.

사용자가 Phone.app에서 직접 받은 뒤 Bridge가 ACTIVE path를 연결할 수 있어야 한다.

---

# 11. JarvisCallAudio HAL Driver

기존 `JarvisVirtualMic.driver`는 폐기한다.

신규 드라이버:

```text
JarvisCallAudio.driver
```

## 11.1 Device Model

```text
JarvisCallAudio.driver

├─ Jarvis Call Capture
│  ├─ Input Stream
│  ├─ Output Stream
│  └─ Internal Loopback
│
└─ Jarvis Call Inject
   ├─ Input Stream
   ├─ Output Stream
   └─ Internal Loopback
```

초기 목표 포맷:

```text
Sample Rate : 48000 Hz
Channels    : 2
Format      : Float32 PCM
Transport   : Virtual
```

전화 AI processing 내부에서는 필요 시 mono로 downmix한다.

## 11.2 Capture Device

목표 경로:

```text
Phone.app
→ macOS Default Output
→ Jarvis Call Capture OUTPUT
→ internal loopback
→ Jarvis Call Capture INPUT
→ Bridge
```

Bridge는 Capture Device의 input stream을 CoreAudio로 직접 읽는다.

## 11.3 Inject Device

목표 경로:

```text
Realtime AI TX
→ Bridge
→ Jarvis Call Inject OUTPUT
→ internal loopback
→ Jarvis Call Inject INPUT
→ macOS Default Input
→ Phone.app
→ Caller
```

Bridge는 Inject Device의 output stream에 CoreAudio로 직접 쓴다.

## 11.4 PCM IPC

v1에서 사용한 별도 POSIX shared memory는 기본 구조에서 사용하지 않는다.

```text
Bridge ↔ Driver PCM
= CoreAudio Device I/O
```

driver control이 필요한 경우 CoreAudio property 또는 maintainable control mechanism을 사용한다.

## 11.5 Device Visibility / Lifecycle

설치된 driver는 유지되더라도 사용자가 평상시 Sound 설정에서 불필요한 Jarvis device를 보지 않도록 한다.

목표:

```text
Idle / ARMED
→ Capture / Inject inactive 또는 non-visible

Call preparation / Active
→ 필요한 device 활성화

Call end
→ device 비활성화 또는 제거
```

구체적인 구현 방식은 다음 후보 중 Phase 1 실험으로 결정한다.

- dynamic device create/destroy
- alive/hidden property
- equivalent CoreAudio lifecycle

특정 방식은 검증 전 PRD에서 강제하지 않는다.

---

# 12. Audio Route Transaction

모든 route 변경은 하나의 transaction으로 취급한다.

## 12.1 Snapshot

전화 개입 직전 다음을 저장한다.

```text
Original Default Input Device
Original Default Output Device
Original Default System Output Device
필요한 추가 CoreAudio route state
```

## 12.2 Active Route

기본 목표:

```text
Default Output
→ Jarvis Call Capture

Default Input
→ Jarvis Call Inject

Default System Output
→ 변경하지 않음
```

System Output을 바꾸지 않아 macOS system alert까지 Capture path로 들어가지 않도록 한다.

## 12.3 Routing Timing

v1에서 착신 대기 중 audio path 개입이 문제를 일으켰으므로 route 변경은 **Ringing 이후**에만 허용한다.

정확한 순서:

```text
route before answer
vs
answer then immediate route
```

는 실제 통화 검증으로 결정한다.

Phase 2/3에서 두 순서를 비교하고 더 안정적인 ordering을 확정한다.

## 12.4 Restore

통화 종료, 오류, 앱 종료, takeover 등 모든 path에서:

```text
Default Input 복원
Default Output 복원
System Output 확인
Capture/Inject stop
Audio device lifecycle 정리
```

를 수행한다.

복원 실패는 critical error로 기록한다.

---

# 13. RX Audio

정의:

```text
RX = 실제 Caller가 말한 음성
```

RX 성공 조건:

```text
Caller가 실제 전화에서 발화
→ Capture input으로 동일 음성이 들어옴
→ Bridge가 재생/분석 가능한 PCM 확보
```

단순 tone, ringtone, system audio는 성공으로 간주하지 않는다.

관찰 항목:

- sample rate
- channel count
- buffer size
- callback interval
- RMS / peak
- dropout
- latency
- caller intelligibility

---

# 14. TX Audio

정의:

```text
TX = Jarvis가 실제 Caller에게 보내는 음성
```

TX 성공 조건:

```text
Bridge가 생성한 test speech
→ Inject output
→ Phone.app input
→ 실제 전화 상대방이 명확히 청취
```

Mac speaker를 통한 acoustic leakage는 성공이 아니다.

Phase 3에서는 AI 연결 전 먼저 deterministic test tone / speech sample로 검증한다.

---

# 15. RX/TX Separation

필수 요구사항:

```text
RX와 TX는 서로 독립적인 logical audio stream이어야 한다.
```

검증 항목:

- RX에 TX가 얼마나 재유입되는지
- 동시에 말할 때 두 stream 유지
- feedback 발생 여부
- end-to-end latency
- stream restart 가능 여부
- 두 번째/세 번째 통화에서 재사용 가능 여부

Echo cancellation은 필요성이 실측된 뒤 추가한다.

---

# 16. Realtime Voice

기본 방향:

```text
Caller RX
↕
Realtime speech-to-speech
↕
Jarvis TX
```

단순:

```text
STT → LLM → TTS
```

직렬 파이프라인을 기본 방식으로 사용하지 않는다.

Realtime provider는 adapter interface를 둬 향후 교체 가능하도록 한다.

PoC 1차 provider:

```text
OpenAI Realtime
```

모델명은 코드 전체에 하드코딩하지 않고 configuration으로 관리한다.

---

# 17. Audio Conversion Pipeline

HAL side:

```text
48kHz / Float32 / Stereo
```

Realtime provider 요구에 따라 Bridge 내부에서 변환한다.

RX:

```text
Capture 48k stereo
→ downmix
→ resample if required
→ realtime input
```

TX:

```text
realtime output
→ decode/convert
→ resample 48k
→ stereo conversion
→ Inject output
```

Realtime audio callback에서 file/network blocking 작업을 수행하지 않는다.

---

# 18. Interruption / Barge-in

강한 UX 원칙:

```text
Caller가 말하기 시작하면
Jarvis는 즉시 말을 멈춘다.
```

처리 순서:

1. Caller speech start 감지
2. local TX playback 즉시 stop
3. 미재생 TX buffer clear
4. 현재 Realtime response cancel
5. 필요한 경우 assistant output context truncate
6. Caller 발화 계속 수신
7. Caller turn 완료
8. 새 context로 response 생성

서버 cancel 응답을 기다린 뒤 local audio를 멈추지 않는다.

```text
Local TX Stop
→ Server Cancel
```

순서가 우선이다.

---

# 19. Pending Speech Intent

중단된 응답에서 Caller에게 전달되지 못한 정보는 별도 semantic state로 관리할 수 있어야 한다.

예:

```text
Pending:
- 오늘 오후 회의
- 택배 도착
- 내일 병원 예약
```

Caller가:

```text
"병원 예약은 취소됐어요."
```

라고 하면:

```text
Pending:
- 오늘 오후 회의
- 택배 도착
```

로 재계산할 수 있어야 한다.

이 기능은 Realtime provider 단독 memory에만 의존하지 않고 Jarvis Agent와 연계 가능한 구조로 설계한다.

---

# 20. Jarvis Agent Integration

Call Bridge는 기존 Jarvis의 business logic을 복제하지 않는다.

```text
Realtime Voice
→ Tool request
→ Bridge / API adapter
→ Existing Jarvis Agent
→ Result
→ Realtime Voice
```

재사용 대상:

- Memory
- Gmail
- Google Calendar
- Approval
- Scheduler
- Web / 기타 Tool
- Agent State

전화라는 이유로 기존 approval policy를 우회하지 않는다.

---

# 21. Realtime Authentication

원칙:

- permanent provider secret을 source code에 하드코딩하지 않는다.
- Bridge의 Jarvis credential은 Keychain에 저장한다.
- 가능하면 Realtime 연결용 short-lived / ephemeral credential을 Jarvis API에서 발급한다.

개념 흐름:

```text
Bridge
→ authenticated Jarvis API
→ ephemeral Realtime credential
→ Realtime provider
```

---

# 22. Human Takeover

Human Takeover는 **AI가 빠지는 것**과 **Bridge가 빠지는 것**을 구분한다.

## 22.1 Mac Takeover

ACTIVE_AI 상태에서 사용자는:

```text
[Mac에서 내가 통화하기]
```

를 선택할 수 있다.

동작:

```text
1. AI TX 즉시 stop
2. 미재생 AI TX buffer clear
3. 현재 Realtime response cancel
4. Realtime session pause/end
5. Capture / Inject 유지
6. Recording 유지
7. RX sink를 사용자 Mac 출력 장치로 전환
8. TX source를 AI → 사용자 Mac 입력 장치로 전환
9. Phone.app 통화 유지
10. 사용자가 동일 통화를 직접 이어감
```

중요:

**Mac Takeover에서는 Original Default Input/Output을 즉시 복원하지 않는다.**

Phone.app의 통화 audio path는 Capture / Inject를 계속 통과하도록 유지하고, Bridge가 사용자의 실제 physical input/output device를 별도 AudioDeviceID로 직접 사용한다.

권장 경로:

```text
Caller
→ Jarvis Call Capture
→ Bridge
├─→ RX Recording
└─→ User Output Device

User Input Device
→ Bridge
├─→ TX Recording
└─→ Jarvis Call Inject
→ Phone.app
→ Caller
```

사용자 출력 장치는 원래 사용하던 Mac speaker/headset을 사용할 수 있고, 입력 장치는 원래 사용하던 microphone/headset을 사용할 수 있다.

speaker + microphone 조합에서는 acoustic echo 가능성이 있으므로 headset을 우선 권장하며, 필요 시 후속으로 AEC를 추가한다.

실제 통화 종료 시에만:

```text
Recording finalize
→ Capture/Inject stop
→ Original Input/Output restore
```

한다.

## 22.2 iPhone Takeover

사용자는 통화 중 iPhone에서 현재 통화를 이어받을 수 있다.

초기 UX:

```text
Jarvis AI 통화
→ 사용자가 iPhone의 현재 통화 표시 / Apple 제공 Handoff UX 사용
→ 통화 endpoint가 Mac → iPhone으로 이동
```

Bridge는 iPhone Handoff를 programmatic public API로 직접 수행할 수 있다고 전제하지 않는다.

Handoff가 감지되면:

```text
AI TX stop
→ Realtime session close
→ Mac recording finalize
→ Capture/Inject processing stop
→ Original Mac audio route restore
→ session metadata에 handoff 기록
```

Mac Bridge는 iPhone으로 넘어간 이후의 통화 음성을 녹음한다고 가정하지 않는다.

## 22.3 Takeover Metadata

통화 기록에는 takeover 정보를 남긴다.

예:

```json
{
  "takeoverType": "mac",
  "takeoverAtMs": 42700,
  "segments": [
    {
      "type": "ai",
      "startMs": 0,
      "endMs": 42700
    },
    {
      "type": "human",
      "startMs": 42700,
      "endMs": 185300
    }
  ]
}
```

iPhone Handoff 예:

```json
{
  "takeoverType": "iphone_handoff",
  "takeoverAtMs": 42700,
  "recordingEndReason": "device_handoff"
}
```

---

# 23. Call End / Cleanup

통화 종료 시 반드시:

```text
1. 남아 있는 AI TX 또는 Human TX stop
2. Realtime session이 존재하면 close
3. Recording이 활성화되어 있으면 finalize
4. Capture input stop
5. Inject output stop
6. Human Takeover용 physical input/output stream stop
7. Original Default Input restore
8. Original Default Output restore
9. System Output invariant 확인
10. Capture/Inject lifecycle 정리
11. Call / AI / Recording session state reset
12. ARMED 복귀
```

iPhone Handoff에서는 Mac 통화 media가 종료되는 시점에 recording을 먼저 finalize한 뒤 restore한다.

cleanup은 중간 단계 실패에도 반복 실행 가능해야 한다.

---

# 24. Recording

초기 v2 개발의 blocker가 아니다.

Phase 7에서 추가한다.

저장 파일:

```text
rx.m4a
tx.m4a
merged.m4a
```

원칙:

- realtime processing은 PCM
- 장기 저장은 AAC/M4A
- RX/TX는 별도 보존
- merged는 Mac에서 생성
- Worker에서 audio merge하지 않음
- Recording lifecycle은 AI lifecycle과 분리한다.
- Mac Takeover 시 AI가 종료되어도 recording은 실제 통화 종료까지 계속한다.
- iPhone Handoff 시 Mac에서 더 이상 통화 media를 확보할 수 없으면 handoff 시점에 recording을 finalize한다.

stream 정의:

```text
rx.m4a
= Bridge가 통화에 참여한 전체 구간의 Caller 음성

tx.m4a
= ACTIVE_AI 구간의 AI 음성
+ ACTIVE_HUMAN_MAC 구간의 사용자 음성

merged.m4a
= RX/TX를 시간축 기준으로 합성한 통화 재생본
```

Mac Takeover 예:

```text
00:00 ───────────── 00:42 ───────────────────── 03:05
       AI 응대             사용자 직접 통화

RX : Caller ───────────────────────────────────────
TX : AI ───────────┊ User ─────────────────────────
REC: ──────────────────────────────────────────────
```

iPhone Handoff 예:

```text
00:00 ───────────── 00:42                    03:05
       AI 응대       │ iPhone 직접 통화
                     │
Mac Recording ───────┘
```

저장 예:

```text
~/Library/Application Support/JarvisCallBridge/
└─ calls/
   └─ {callId}/
      ├─ rx.m4a
      ├─ tx.m4a
      ├─ merged.m4a
      └─ metadata.json
```

---

# 25. Cloud Persistence

기존 Jarvis backend를 사용한다.

```text
Cloudflare Workers
Cloudflare Agents
Durable Objects
SQLite
R2
```

권장 flow:

```text
POST /api/calls
→ callId

통화

→ recording finalize
→ merged.m4a 생성

→ R2 direct upload
→ POST /api/calls/{callId}/complete
```

SQLite에는 대형 audio binary를 저장하지 않는다.

저장 대상:

- callId
- caller metadata
- startedAt
- endedAt
- duration
- transcript
- summary
- action result
- RX R2 key
- TX R2 key
- merged R2 key
- failure state
- takeover type
- takeover timestamp
- AI/Human segment metadata
- recording end reason

---

# 26. Call Summary

Call Bridge가 독립적으로 summary business logic을 만들지 않는다.

```text
Call Bridge
→ transcript
→ Jarvis Agent
→ summary
→ SQLite
```

예:

```text
상대방:
거래처 담당자

용건:
금요일 회의 시간을 오후 4시로 변경 요청.

Jarvis 처리:
Calendar 조회.

결과:
오후 4시 가능.

후속 조치:
사용자 승인 필요.
```

---

# 27. 업무 모드 정책

초기 정책:

```text
Work Mode OFF
→ Bridge no intervention

Work Mode ON
→ incoming detection
→ configured delay
→ auto answer
```

후속 설정 후보:

- 업무시간 자동 ON/OFF
- 특정 연락처 예외
- 가족/긴급 연락처 직접 수신
- unknown caller only AI
- 특정 시간대 AI 우선

v2 초기 PoC에서는 복잡한 routing rule을 넣지 않는다.

---

# 28. UI

최종 기본 UI:

```text
Jarvis Call Bridge

Work Mode                    [ ON ]

Status
● Waiting for calls

iPhone Continuity             Ready / Unknown
Phone.app                     Ready / Not Available
Accessibility                 Granted / Required
Audio Driver                  Ready / Error
Jarvis Cloud                  Connected / Disconnected
Realtime                      Idle / Connected

Auto Answer
3 seconds after ringing

Current Call
Idle

[Mac에서 내가 통화하기]   # ACTIVE_AI일 때
[iPhone에서 계속하기 안내] # ACTIVE_AI일 때

Recording
● Recording / Finalized / Disabled

Recent Call
11:32
2m 14s
"프로젝트 일정 문의"
```

개발 진단 UI는 production UI와 분리할 수 있다.

---

# 29. 권한

필요 권한 후보:

- Accessibility
- Microphone: 실제 구현 필요 여부에 따라
- Contacts: Caller 표시가 필요할 때 후속
- Network

v2 primary RX는 ScreenCaptureKit을 사용하지 않으므로 Screen/System Audio Recording 권한을 기본 요구사항으로 두지 않는다.

권한을 요구하는 이유를 UI에서 명확히 설명한다.

---

# 30. Local Logging

구조화된 이벤트 로그를 제공한다.

예:

```text
[BRIDGE] mode=armed
[PHONE] incoming detected
[CALL] state=ringing
[CALL] caller=...
[AUDIO] snapshot input=...
[AUDIO] snapshot output=...
[AUDIO] capture device ready
[AUDIO] inject device ready
[AUDIO] route switched
[CALL] answer requested
[CALL] state=active
[RX] started
[TX] started
[REALTIME] connected
[REALTIME] speech_started
[REALTIME] response_started
[REALTIME] response_cancelled
[TAKEOVER] requested
[CALL] ended
[AUDIO] restoring
[AUDIO] restored
[BRIDGE] mode=armed
```

기록 금지:

- API Secret
- permanent credential
- raw PCM dump의 무조건적 로그
- 민감한 tool payload 전체

Diagnostic audio dump는 명시적인 개발 모드에서만 허용한다.

---

# 31. 장애 처리

## 31.1 Incoming detection 실패

- native Phone.app 착신을 방해하지 않는다.
- 자동 수신을 수행하지 않는다.
- 사용자가 직접 전화를 받을 수 있어야 한다.

## 31.2 Audio driver 실패

- auto-answer 전에 실패를 알 수 있으면 자동 수신을 취소한다.
- 이미 통화 중이면 restore/takeover path를 우선한다.

## 31.3 RX 실패

- 임의의 AI 응답을 계속하지 않는다.
- 사용자 takeover 또는 graceful termination으로 전환한다.

## 31.4 TX 실패

- AI 출력 중단
- 가능한 경우 human takeover 제공

## 31.5 Realtime 실패

- audio route를 정상 복구한다.
- native 통화를 가능한 한 유지한다.
- human takeover 우선

## 31.6 App crash

다음 실행 시 stale audio route를 감지해 복구할 수 있는 startup recovery를 구현한다.

## 31.7 Route restore 실패

critical error.

사용자에게 명확히 표시하고 원래 device를 선택할 수 있는 recovery UI 또는 명령을 제공한다.

---

# 32. Startup Recovery

Bridge 시작 시:

```text
Current default input/output 확인
Jarvis Call Capture/Inject가 비정상 default로 남았는지 확인
이전 session marker 확인
```

stale state라면:

```text
safe restore
→ device cleanup
→ ARMED
```

로 복구한다.

복구 가능한 원본 device 정보는 call session 시작 시 안전하게 저장한다.

---

# 33. 성능 요구사항

- realtime audio callback에 blocking network/file I/O 금지
- audio buffer underrun 최소화
- call answer 후 AI 첫 발화 latency 최소화
- barge-in local stop은 server round-trip과 독립적으로 즉시 수행
- driver와 Bridge CPU 사용량을 개인 Mac 환경에서 상시 사용 가능한 수준으로 유지
- ARMED 상태 CPU 사용량은 매우 낮아야 한다

---

# 34. 보안 요구사항

- Jarvis token: Keychain
- provider secret source code 저장 금지
- R2 permanent credential 앱 내 하드코딩 금지
- 최소 권한
- logs에 secret 출력 금지
- driver control endpoint가 있다면 local unauthorized process의 오용 방지 고려
- 개인용 PoC라도 world-writable shared memory 방식은 v2에서 사용하지 않는다

---

# 35. 개발 위치

Repository 최상위 구조는 유지한다.

```text
jarvis/
├─ admin/
├─ api/
├─ bridge/
├─ docs/
└─ web/
```

Call Bridge 코드는 **`bridge/`에 직접 작성한다.**

다음 폴더는 만들지 않는다.

```text
bridge/call-bridge/
swift/
mac/
desktop/
callbridge/
```

권장 v2 내부 구조:

```text
bridge/
├─ Package.swift
├─ Info.plist
│
├─ Sources/
│  └─ JarvisCallBridge/
│     ├─ App/
│     ├─ Call/
│     ├─ Audio/
│     ├─ Realtime/
│     ├─ Jarvis/
│     ├─ Storage/
│     └─ UI/
│
├─ AudioDriver/
│  ├─ Plugin/
│  ├─ Devices/
│  ├─ Shared/
│  └─ Tests/
│
├─ Scripts/
│  ├─ build-app.sh
│  ├─ build-driver.sh
│  ├─ install-driver.sh
│  └─ uninstall-driver.sh
│
└─ Tests/
```

구체적인 폴더는 구현 필요에 따라 단순화할 수 있지만 top-level `bridge/` 원칙은 고정한다.

---

# 36. v1 Legacy 처리

v1.x 구현은 이미 Git history/tag로 보존한다.

v2에서 다음을 재사용하지 않는다.

```text
v1 ScreenCaptureKit RX production path
JarvisVirtualMic.driver
POSIX shared memory ring
Start Test orchestration
```

다만 다음 조사 결과는 지식으로 유지한다.

- macOS native CallKit 제한
- Phone.app bundle / Accessibility 조사
- Continuity 실기기 조건
- 기존 build/package 경험
- HAL AudioServerPlugIn 구현 경험
- real-device validation 절차

기존 Phase 0 보고서는 삭제하지 않는다.

---

# 37. 개발 Phase

## CB v2 Phase 0 — Clean Slate & Architecture Skeleton

목표:

- v1 의존성 제거 확인
- v2 project skeleton 구성
- 상태 머신 구현
- Work Mode OFF/ON
- ARMED 상태 구현
- Phone.app discovery
- Accessibility permission/status
- audio route snapshot/restore abstraction
- 아직 actual HAL route switch 금지

완료 기준:

```text
Work Mode ON 상태에서
실제 Phone.app 착신이 정상 동작한다.
```

최소 10회 연속 착신 확인.

---

## CB v2 Phase 1 — Dual Loopback Audio Driver

목표:

```text
Jarvis Call Capture
Jarvis Call Inject
```

두 device 구현.

검증:

```text
Local audio
→ Capture output
→ Capture input
→ 동일 audio 확인

Bridge test audio
→ Inject output
→ Inject input
→ 동일 audio 확인
```

실제 전화 연결은 아직 하지 않는다.

완료 기준:

- 48k Float32 stereo loopback
- 안정적인 create/destroy 또는 activate/deactivate
- 반복 start/stop
- no crash
- route restore primitive 검증

---

## CB v2 Phase 2 — Incoming Call Lifecycle

목표:

- ARMED
- Ringing 감지
- Accessibility auto answer
- End 감지
- restore

중요:

**audio route를 바꾸지 않은 상태의 auto-answer lifecycle부터 검증한다.**

완료 기준:

```text
ARMED
→ 실제 착신
→ 자동 수신
→ 통화 유지
→ 종료
→ ARMED
```

최소 여러 회 반복 성공.

---

## CB v2 Phase 3 — Real Call Audio

목표:

- 실제 caller RX
- 실제 caller TX
- dual device routing
- route ordering 확정

검증 순서:

1. RX only
2. TX only
3. simultaneous RX/TX
4. second call reuse
5. route restore
6. crash/error restore

완료 기준:

```text
Caller 실제 음성 → Bridge RX
Bridge test speech → 실제 Caller
```

둘 다 human-verifiable하게 성공.

---

## CB v2 Phase 4 — Realtime Voice

목표:

- Realtime provider 연결
- speech-to-speech
- VAD
- barge-in
- local TX clear
- response cancel

완료 기준:

실제 전화 상대방과 AI가 자연스럽게 여러 turn 대화하고, Caller interruption 시 AI가 즉시 멈춘다.

---

## CB v2 Phase 5 — Jarvis Agent Integration

목표:

- Jarvis authentication
- Memory
- Tool call
- Approval
- Scheduler
- existing Agent state

완료 기준:

전화 중 Jarvis가 기존 Agent 기능을 실제로 사용할 수 있다.

---

## CB v2 Phase 6 — Work Assistant UX

목표:

- Work Mode UI
- Auto Answer delay
- Mac Human Takeover
- iPhone Handoff 안내/감지
- AI lifecycle과 call lifecycle 분리
- failure UX
- recent call basic view
- startup recovery

완료 기준:

개발용 버튼 없이 일반 앱 흐름으로 업무 중 반복 사용할 수 있다.

---

## CB v2 Phase 7 — Recording & History

목표:

- rx.m4a
- tx.m4a
- merged.m4a
- AI → Mac Human Takeover 이후에도 recording 지속
- iPhone Handoff 시 recording finalize
- AI/Human segment metadata
- transcript
- summary
- R2 upload
- SQLite metadata

완료 기준:

통화 종료 후 Admin/API에서 통화 기록과 녹음 위치를 확인할 수 있다.

---

## CB v2 Phase 8 — Distribution & Hardening

목표:

- production `.app`
- Developer ID signing
- notarization
- `.dmg`
- permissions onboarding
- update strategy
- uninstall/recovery documentation

완료 기준:

개발 환경이 아닌 Mac에서도 반복 설치/실행/삭제 가능한 배포 artifact를 만든다.

---

# 38. Phase Gate 원칙

다음 Phase로 자동 진행하지 않는다.

각 Phase는 다음 중 하나로 판정한다.

```text
PASS
CONDITIONAL PASS
FAIL
```

FAIL 또는 unresolved critical issue가 있으면 다음 Phase로 진행하지 않는다.

특히 다음은 blocker이다.

- ARMED가 native incoming call을 방해함
- audio route restore 실패
- actual Caller RX 미확보
- actual Caller TX 미전달
- repeat call에서 route/device가 깨짐

---

# 39. 실제 통화 Acceptance Test

최소 시나리오:

## Scenario A — Work Mode OFF

```text
Bridge 실행
Work Mode OFF
외부 전화
→ 정상 native 착신
```

PASS 필수.

## Scenario B — Work Mode ON / No Intervention Before Ring

```text
Work Mode ON
ARMED
외부 전화
→ 정상 native 착신
```

PASS 필수.

## Scenario C — Auto Answer

```text
Ringing
→ configured delay
→ Jarvis auto answer
→ 통화 Active
```

PASS 필수.

## Scenario D — RX

Caller:

```text
"하나 둘 셋 넷 다섯.
지금 Jarvis RX 테스트 중입니다."
```

Bridge에서 동일 음성을 확인해야 한다.

## Scenario E — TX

Bridge test speech가 실제 상대방 전화에서 명확하게 들려야 한다.

## Scenario F — Simultaneous

Caller와 Jarvis TX가 동시에 활성화돼도 두 stream이 유지되어야 한다.

## Scenario G — Restore

통화 종료 후 기존 Mac Default Input/Output이 정확히 복원되어야 한다.

## Scenario H — Second Call

앱 재시작 없이 두 번째 실제 통화를 정상 처리해야 한다.

## Scenario I — Mac Human Takeover + Continuous Recording

```text
ACTIVE_AI
→ 사용자가 Mac Takeover
→ AI 즉시 종료
→ 동일 전화 통화 유지
→ 사용자가 Mac Mic/Headset으로 직접 대화
→ RX/TX recording 계속
→ 실제 통화 종료
→ recording finalize
→ route restore
```

PASS 조건:

- Takeover 때문에 전화가 끊기지 않는다.
- Takeover 이후 Caller와 사용자가 양방향 대화할 수 있다.
- AI 음성은 더 이상 Caller에게 전달되지 않는다.
- `rx.m4a`에는 takeover 전후 Caller 음성이 연속적으로 존재한다.
- `tx.m4a`에는 AI 구간과 사용자 구간이 동일 timeline에 기록된다.
- 통화 종료 후 route가 정확히 복원된다.

## Scenario J — iPhone Handoff

```text
ACTIVE_AI
→ 사용자가 Apple 제공 UX로 iPhone에서 통화 이어받기
→ AI 종료
→ Mac recording finalize
→ Mac route restore
→ iPhone 통화는 계속
```

PASS 조건:

- Handoff 때문에 상대방과의 전화 자체가 끊기지 않는다.
- Mac의 AI output이 Handoff 이후 전달되지 않는다.
- Mac recording이 handoff 시점까지 정상 finalize된다.
- metadata에 `iphone_handoff`와 takeover timestamp가 기록된다.
- Bridge는 iPhone Handoff 이후 구간의 녹음을 보장한다고 표시하지 않는다.

---

# 40. v2 초기 제외 범위

- Android
- iPhone Jarvis app
- Apple Watch
- SIP
- 070
- Twilio
- BYOC
- carrier API
- 외출 중 always-on remote answering
- multi-user SaaS
- billing
- plan
- usage limit
- Local LLM
- Vector DB
- RAG
- DTMF / IVR
- advanced call transfer
- multi-call concurrency
- multi-iPhone
- custom voice cloning
- programmatic / automatic iPhone Handoff triggering (사용자 주도 Apple Handoff는 지원)

---

# 41. 성공 기준

v2의 최종 성공 조건:

```text
업무 모드 ON
↓
기존 iPhone 번호로 전화 수신
↓
Mac Phone.app 정상 착신
↓
Jarvis 자동 수신
↓
Caller RX 확보
↓
Realtime AI 대화
↓
Jarvis TX 실제 전달
↓
Caller interruption 즉시 처리
↓
필요 시 Jarvis Tool 사용
↓
필요 시 Mac Human Takeover 또는 iPhone Handoff
↓
Mac Takeover라면 녹음 계속
↓
통화 종료 또는 iPhone Handoff
↓
오디오 route 완전 복구
↓
다음 전화 대기
```

그리고 가장 중요한 비기능 성공 기준:

```text
Jarvis Call Bridge가 고장 나더라도
기본 iPhone / Phone.app 통화 기능을 가능한 한 망가뜨리지 않는다.
```

---

# 42. 기술 결정 요약

| 영역 | v1.x | v2.0 |
|---|---|---|
| RX | ScreenCaptureKit | **Dual HAL Capture loopback** |
| TX | Virtual Mic + shared memory | **Dual HAL Inject loopback** |
| PCM 전달 | POSIX shared memory | **CoreAudio direct I/O** |
| 착신 대기 | Start Test 기반 | **ARMED 상태, audio untouched** |
| 자동 수신 | 실험적 AX state | **Accessibility primary** |
| CallKit | direct API 탐색 | **의존하지 않음** |
| Audio device | 단일 input | **Capture + Inject** |
| Route | 수동/실험적 | **transactional snapshot/restore** |
| AI | Realtime 예정 | **Realtime speech-to-speech** |
| Jarvis | 후속 연결 | **기존 Agent/Tools 재사용** |
| Human Takeover | 단순 직접 통화 전환 | **Mac Takeover(녹음 지속) + iPhone Handoff(녹음 finalize)** |
| 목적 | 기술 PoC | **개인 업무용 실사용 Bridge** |

---

# 43. 실기기 검증에서 얻은 근거

v2는 추측만으로 설계하지 않는다.

현재까지 실제 환경에서 확인한 사실:

1. Mac Studio의 Phone.app에서 iPhone 셀룰러 회선을 이용한 발신이 가능하다.
2. iPhone Continuity 설정을 정상화한 뒤 Mac Studio에서 실제 착신 전화가 표시된다.
3. AITakeCall은 macOS 착신 전화를 Accessibility 기반으로 자동 수신한다.
4. AITakeCall 통화 중 `AI Take Call Capture`가 Default Output Device가 된다.
5. AITakeCall 통화 중 `AI Take Call Inject`가 Default Input Device가 된다.
6. 두 장치는 48kHz, 2 input / 2 output channel을 가진 virtual CoreAudio device로 관찰됐다.
7. 해당 reference driver binary에는 `LoopbackHandler`가 존재한다.
8. AITakeCall에서 실제 AI 통화가 시작되는 것을 확인했다.
9. iPhone Wi-Fi를 끄면 AITakeCall도 Mac에서 착신 연결되지 않았다.
10. v1 Bridge의 Start Test 활성화 상태에서는 Mac 착신이 나타나지 않는 문제가 관찰됐다.

이 결과를 기반으로 v2는 **착신 전 대기 상태와 실제 통화 오디오 상태를 완전히 분리**한다.

---

# 44. 문서/보고서 보존 정책

기존 문서는 역사적 조사 결과로 유지한다.

예:

```text
docs/
├─ Jarvis_Call_Bridge_Client_PRD.md        # 항상 최신 PRD
├─ Call_Bridge_Phase_0_Feasibility_Report.md
└─ Call_Bridge_Phase_0_PhoneApp_Feasibility_Report.md
```

PRD filename에는 version을 붙이지 않는다.

```text
Jarvis_Call_Bridge_Client_PRD.md
```

문서 내부의 `문서 버전`으로 버전을 관리한다.

---

# 45. v2.1 기능 추가

v2.1에서 Human Takeover와 Recording lifecycle을 구체화했다.

핵심 변경:

```text
AI lifecycle ≠ Call lifecycle ≠ Recording lifecycle
```

- **Mac Takeover:** AI만 종료하고 Bridge/Capture/Inject/Recording은 통화 종료까지 유지
- **iPhone Takeover:** Apple 사용자 주도 Handoff를 허용하고 Mac recording은 handoff 시점에 finalize
- `ACTIVE_AI`, `ACTIVE_HUMAN_MAC`, `HANDOFF_TO_IPHONE` 상태를 명시
- RX/TX recording에 AI/Human segment metadata 추가
- programmatic/private iPhone Handoff는 전제하지 않음

---

# 46. 다음 개발 시작점

v2의 첫 구현 작업은:

```text
CB v2 Phase 0
Clean Slate & Architecture Skeleton
```

이다.

Phase 0에서 HAL driver나 Realtime AI를 먼저 구현하지 않는다.

가장 먼저 증명할 것은:

```text
Bridge 실행
+
Work Mode ON
+
ARMED
+
실제 iPhone 착신

→ 아무 문제 없이 Mac Phone.app에 정상 표시
```

이다.

**착신 대기 안정성이 확보된 뒤에만 v2의 오디오 기능을 단계적으로 추가한다.**
