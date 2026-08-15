# Jarvis Call Bridge Client PRD

## 1. 문서 개요

- 프로젝트명: Jarvis
- 모듈명: Call Bridge Client
- 문서 버전: v1.1
- 개발 단계: Jarvis Phase 7-1 이후 별도 PoC
- 대상 플랫폼: macOS 26 이상
- 기본 통화 Host: macOS Phone.app
- 개발 언어: Swift
- UI Framework: SwiftUI
- 목적: iPhone의 기존 셀룰러 번호를 유지하면서 macOS 26+의 Phone.app 및 iPhone Cellular Calls/Continuity 경로를 이용해 Jarvis AI가 실제 전화 통화에 개입할 수 있는 Call Bridge를 구현한다.
- 대상 사용자: 초기 단일 사용자 본인
- SaaS / 멀티사용자 기능: 제외

---

## 2. v1.1 변경 요약

v1.0의 전체 제품 방향은 유지한다.

Phase 0 조사 결과 다음이 확인되었다.

- 네이티브 macOS에서 `CXCallObserver`를 이용한 직접 Continuity call-state 감지는 사용할 수 없었다.
- FaceTime 프로세스 출력 오디오를 ScreenCaptureKit으로 캡처하는 RX 후보는 구현됐지만 실제 iPhone 셀룰러 통화에서 caller voice 포함 여부는 미검증이다.
- Continuity 통화 송신 stream에 직접 PCM을 주입하는 공개 API는 확인되지 않았다.
- 공개 Core Audio / AudioDriverKit 기반 Virtual Audio Input 방식은 아직 검증하지 않았다.
- 따라서 "직접 Continuity API가 없다"는 이유만으로 Call Bridge 전체를 실패로 판정하지 않는다.

v1.1에서는 다음 방향으로 변경한다.

```text
기존
iPhone
  ↓
Continuity
  ↓
Mac
  ↓
Direct Call API / Direct TX API 탐색

변경
iPhone Cellular Call
  ↓
Calls on Other Devices / Continuity
  ↓
macOS 26+ Phone.app
  ├─ RX: Phone.app output capture
  └─ TX: Virtual Audio Input → Phone.app microphone
       ↓
Jarvis Call Bridge
```

Phase 0의 목표는 특정 API 사용 여부가 아니라 **실제 양방향 통화 오디오 경로를 유지보수 가능한 방식으로 증명하는 것**으로 재정의한다.

---

# 3. 목표

Jarvis Call Bridge Client는 사용자의 Mac에 설치되는 macOS 애플리케이션이다.

주요 목표:

1. 사용자의 기존 iPhone 셀룰러 번호를 그대로 사용한다.
2. iPhone의 Calls on Other Devices / Continuity 기능을 통해 Mac에서 셀룰러 통화를 처리한다.
3. macOS 26+의 Phone.app을 기본 통화 Host로 사용한다.
4. 실제 상대방 음성(RX)을 Call Bridge가 실시간으로 확보한다.
5. Jarvis가 생성한 음성(TX)을 Phone.app의 microphone/input 경로를 통해 실제 상대방에게 전달한다.
6. RX/TX를 가능한 한 독립적인 audio path로 유지한다.
7. 실시간 AI Voice 모델과 양방향 음성 통화를 연결한다.
8. 상대방이 AI 발화 중 말을 시작하면 AI 출력을 즉시 중단한다.
9. 중단된 발화 내용과 상대방의 새 발화를 함께 고려해 다음 응답을 생성한다.
10. RX/TX를 Mac에서 별도 녹음한다.
11. 통화 종료 후 Mac에서 RX + TX를 `merged.m4a`로 생성한다.
12. RX/TX/Merged 녹음 파일을 Cloudflare R2에 업로드한다.
13. 통화 메타데이터, transcript, summary, R2 object key를 기존 Jarvis Agent의 SQLite에 저장한다.
14. 최종적으로 `.app`을 만들고, 안정화 후 DMG로 패키징할 수 있어야 한다.

---

# 4. 가장 중요한 PoC 전제

이 프로젝트에서 가장 큰 기술 리스크는 AI 모델이 아니라 **macOS Phone.app을 중심으로 실제 셀룰러 통화의 RX와 TX를 Jarvis가 안정적으로 연결할 수 있는가**이다.

Phase 0에서는 다음 두 경로가 가장 중요하다.

## 4.1 RX 경로

```text
Caller
  ↓
iPhone Cellular
  ↓
Continuity / Calls on Other Devices
  ↓
macOS Phone.app
  ↓
Phone.app Process Output
  ↓
Call Bridge RX Buffer
```

후보 기술:

- ScreenCaptureKit application audio capture
- Core Audio process tap
- 기타 Apple 공개 audio capture API

단순 microphone capture 또는 전체 system audio capture만으로 성공 처리하지 않는다.

실제 caller voice가 RX buffer에 포함되는 것을 실제 통화로 검증해야 한다.

## 4.2 TX 경로

직접 Continuity TX API를 전제로 하지 않는다.

우선 검증할 구조:

```text
Jarvis/Test Audio
  ↓
Call Bridge
  ↓
Virtual Audio Input Device
  ↓
Phone.app Microphone/Input
  ↓
Continuity
  ↓
iPhone Cellular
  ↓
Caller
```

후보 기술:

- AudioDriverKit 기반 virtual audio device
- Apple이 지원하는 Core Audio audio-driver / virtual-device 방식
- 유지보수 가능한 기타 공개 audio routing 방식

Phase 0에서는 수동으로 Phone.app의 input device를 선택해야 해도 허용한다.

자동 장치 선택/복구는 후속 Phase에서 개선할 수 있다.

---

# 5. Phase 0 판정 원칙

직접 CallKit 또는 직접 Continuity TX API가 없다는 사실만으로 Phase 0을 FAIL 처리하지 않는다.

판정 기준은 다음이다.

```text
특정 API 존재 여부
≠
Call Bridge 가능 여부

실제 Caller RX 확보
+
실제 Caller에게 TX 전달
+
RX/TX를 실사용 가능한 형태로 유지
=
Call Bridge 핵심 가능성
```

Call-state detection은 중요하지만 Phase 0의 최우선 blocker는 아니다.

양방향 오디오가 성공하고 call-state 자동 감지만 미해결인 경우:

```text
CB Phase 0 = CONDITIONAL PASS
```

를 허용한다.

PoC에서는 사용자가 Call Bridge의 Start/Stop을 수동으로 제어하는 방식으로 Phase 1을 진행할 수 있다.

단, 최종 제품 단계에서는 자동 call-state detection 또는 이에 준하는 안정적인 lifecycle 관리가 필요하다.

---

# 6. 시스템 구조

```text
Caller
  │
  │ PSTN / Cellular
  ▼
User iPhone
  │
  │ Calls on Other Devices / Continuity
  ▼
macOS 26+ Phone.app
  │
  ├──────────── RX ───────────────┐
  │                               │
  │        Process Audio Capture  │
  │        - ScreenCaptureKit     │
  │        - Core Audio Tap       │
  │                               ▼
  │                      Jarvis Call Bridge
  │                               │
  │                         Realtime Voice
  │                               │
  │                               ▼
  └──── TX ◀── Virtual Input ◀── AI Audio
```

Jarvis 연동:

```text
Jarvis Call Bridge
       │
       ├─ Realtime Audio Session
       │
       └─ Jarvis API / Agent
              ├─ Memory
              ├─ Tools
              ├─ Approval
              ├─ Scheduler
              └─ Agent State
```

통화 종료 후:

```text
Call Bridge (Mac)
  │
  ├─ rx.m4a
  ├─ tx.m4a
  └─ merged.m4a
  │
  ├──────────────→ Cloudflare R2
  │
  └──────────────→ Jarvis Call API
                         │
                         ▼
               Durable Object SQLite
```

---

# 7. 기본 원칙

## 7.1 Mac은 Call/Audio Bridge

Mac에서는 가능한 한 AI inference를 수행하지 않는다.

```text
Mac
= Phone.app integration
+ Audio Bridge
+ Recording
+ Local Merge
+ Cloud connectivity

Cloud / Realtime Provider
= AI
```

초기 PoC에서 Local LLM을 사용하지 않는다.

## 7.2 1 User = 1 Mac = 1 Bridge

PoC에서는 다음만 지원한다.

```text
사용자 1명
+
iPhone 1대
+
Mac 1대
+
Call Bridge Client 1개
```

지원하지 않음:

- Mac 1대에서 여러 Call Bridge 동시 실행
- 여러 사용자 동시 처리
- 여러 Apple Account 동시 처리
- Multi-tenant macOS host

## 7.3 기존 번호 유지

다음은 사용하지 않는다.

- Twilio 번호
- 번호이동
- SIP
- BYOC
- 별도 070/VoIP 번호

사용자의 기존 iPhone 셀룰러 번호를 그대로 사용한다.

## 7.4 Phone.app 우선

macOS 26+에서는 Phone.app을 기본 통화 Host로 사용한다.

FaceTime 기반 경로는 필요할 경우 fallback/비교 검증 용도로만 사용할 수 있다.

## 7.5 Public / Maintainable Path 우선

다음을 우선한다.

- Apple Public API
- AudioDriverKit
- Core Audio
- ScreenCaptureKit
- Accessibility 등 Apple 공개 프레임워크
- 사용자가 명시적으로 승인한 macOS 권한

다음을 제품 기본 구조로 사용하지 않는다.

- binary hooking
- process injection
- 임의 patch
- undocumented private framework에 강하게 의존하는 구조

---

# 8. 기술 스택

## 8.1 macOS Client

- Swift
- SwiftUI
- AVFoundation
- AVAudioEngine
- AudioToolbox
- Core Audio
- ScreenCaptureKit
- AudioDriverKit 검토
- Accessibility API 검토
- URLSession
- WebSocket
- Keychain

## 8.2 Realtime Voice

기본 후보:

- OpenAI Realtime API
- speech-to-speech realtime model
- VAD / turn detection
- interruption / barge-in
- response cancellation

모델 이름을 코드에 강하게 고정하지 않는다.

Realtime Voice Provider는 향후 교체 가능하도록 최소 추상화를 둔다.

## 8.3 Backend

기존 Jarvis 사용:

- Cloudflare Workers
- Cloudflare Agents SDK
- Durable Objects
- SQLite
- R2

---

# 9. Phone.app / Continuity 요구사항

Call Bridge가 동작하려면 사용자의 Apple 환경에서 iPhone cellular calls가 Mac으로 relay 가능한 상태여야 한다.

PoC 기준:

- macOS 26 이상
- iPhone과 Mac이 동일 Apple Account 기반으로 연동
- iPhone에서 Calls on Other Devices 활성화
- Mac에서 iPhone cellular calls 사용 가능
- Phone.app에서 실제 수신/발신 통화가 가능한 상태

Call Bridge는 통신사 회선을 직접 제어하지 않는다.

```text
Carrier
↔
iPhone
↔
Apple Continuity
↔
Phone.app
↔
Call Bridge
```

---

# 10. Call State

네이티브 macOS에서 iPhone cellular call state를 제공하는 직접 CallKit API를 전제로 하지 않는다.

## 10.1 목표 상태

가능하면 다음 상태를 자동 감지한다.

```text
Idle
Ringing
Active
Ended
```

## 10.2 후보 접근

유지보수 가능한 공개 방식만 검토한다.

예:

- Phone.app의 공개 observable state
- Accessibility API를 통한 Phone.app UI state
- 공개 notification/event
- window/session 상태
- audio stream lifecycle
- 기타 공개 macOS mechanism

각 후보는 실제 call-state 의미를 제대로 나타내는지 검증해야 한다.

단순히 Phone.app 프로세스가 실행 중이라는 이유로 `Active Call`로 판정하지 않는다.

## 10.3 PoC fallback

자동 Call State가 확보되지 않아도 양방향 오디오가 성공하면 Phase 0은 `CONDITIONAL PASS`가 가능하다.

그 경우 초기 UI는:

```text
[Start Bridge]
[Stop Bridge]
```

를 제공해 사용자가 실제 통화 시작/종료 시점에 수동으로 bridge session을 관리할 수 있다.

---

# 11. RX Audio Capture

RX는 실제 상대방 음성을 의미한다.

```text
RX = Caller → Phone.app → Call Bridge
```

우선 검증 순서:

1. Phone.app process identification
2. ScreenCaptureKit application audio
3. Core Audio process tap
4. 실제 caller voice 포함 여부
5. sample format / latency 확인
6. 통화 중 지속성 확인

로그 가능한 정보:

- source process
- sample rate
- channels
- PCM format
- frames
- callback interval
- PTS
- buffer count
- amplitude/level

RX 성공 조건:

```text
실제 외부 Caller가 발화
↓
Call Bridge RX buffer에서 해당 음성이 확인됨
```

벨소리나 Phone.app UI sound만 잡히는 것은 성공이 아니다.

---

# 12. TX Audio Routing

TX는 Jarvis가 실제 전화 상대방에게 보내는 음성이다.

```text
TX = Call Bridge → Phone.app input → Caller
```

직접 Continuity PCM injection API를 요구하지 않는다.

## 12.1 Phase 0 기본 전략

Virtual Audio Input Device를 우선 검증한다.

```text
Test/AI PCM
↓
Virtual Audio Device
↓
Phone.app input device
↓
Caller
```

Phase 0에서는:

- 수동 device selection 허용
- test tone 또는 local audio 사용
- AI 연결 불필요

TX 성공 조건:

```text
Mac speaker acoustic leakage가 아닌 상태에서
Call Bridge에서 생성한 test audio를
실제 전화 상대방이 명확히 들음
```

Mac speaker를 통해 물리적으로 microphone에 다시 들어간 음성은 TX 성공으로 간주하지 않는다.

---

# 13. RX/TX Separation

최종 목표:

```text
RX stream
= Phone.app → Call Bridge

TX stream
= Call Bridge → Virtual Input → Phone.app
```

검증:

- RX와 TX가 서로 다른 logical stream인지
- TX가 RX capture에 어느 정도 포함되는지
- Caller와 Jarvis가 동시에 말할 때 양쪽 오디오를 보존 가능한지
- echo/feedback 수준
- 별도 recording 가능 여부
- barge-in에 사용할 수 있는 latency인지

필요 시 echo cancellation을 후속 Phase에서 추가한다.

Phase 0에서는 우선 separation capability와 feedback level을 측정한다.

---

# 14. Call Bridge Client 상태 UI

최종 PoC UI의 기본 상태:

```text
Jarvis Call Bridge

Phone.app             Available / Not Available
iPhone Calls          Ready / Unknown
Call State            Idle / Ringing / Active / Manual
RX Audio              Active / Inactive
TX Audio              Active / Inactive
RX/TX Separation      Pass / Conditional / Fail

Jarvis Cloud          Connected / Disconnected
Realtime Voice        Connected / Disconnected

AI Bridge             ON / OFF
Recording             ON / OFF
```

Phase 0에서는 Feasibility UI를 간소화할 수 있다.

---

# 15. 수신 통화

목표 흐름:

```text
Caller
↓
사용자 기존 iPhone 번호
↓
iPhone
↓
Continuity
↓
macOS Phone.app
↓
Call Bridge
↓
Jarvis AI
```

PoC 최소 요구:

- Mac Phone.app에서 실제 수신 통화 가능
- RX caller audio 확보
- TX test/AI audio 전달
- bridge session 시작/종료
- 자동 call-state가 불가능하면 manual start/stop 허용

---

# 16. 발신 통화

목표:

```text
Phone.app / Call Bridge
↓
Continuity
↓
iPhone cellular line
↓
Caller
```

초기 우선순위는 수신이다.

수신 양방향 오디오가 검증된 후 발신에도 동일 RX/TX bridge가 적용되는지 확인한다.

Call Bridge가 직접 carrier dialing API를 구현할 필요는 없다.

PoC에서는 Phone.app에서 사용자가 직접 발신해도 된다.

---

# 17. Realtime Conversation

단순한:

```text
STT → LLM → TTS
```

직렬 파이프라인을 기본 방식으로 사용하지 않는다.

목표:

```text
Caller RX
   ↕
Realtime Voice Model
   ↕
Jarvis TX
```

실시간 speech-to-speech conversation을 우선한다.

---

# 18. Interruption / Barge-in

Jarvis가 말하는 중 Caller가 발화를 시작하면:

1. Caller speech 시작 감지
2. TX playback 즉시 중단
3. 아직 재생되지 않은 local output buffer 폐기
4. Realtime response cancel
5. 필요하면 미청취 assistant context truncate
6. Caller 발화 수신 완료
7. 새로운 Caller input 반영
8. 아직 전달되지 않은 기존 핵심 정보 재계산
9. 새 응답 생성

강한 UX 원칙:

```text
Caller가 말하기 시작하면
Jarvis는 즉시 말을 멈춘다.
```

---

# 19. Pending Speech Intent

응답 cancellation만으로는 충분하지 않다.

Jarvis가 아직 Caller에게 전달하지 못한 핵심 내용을 별도로 관리할 수 있어야 한다.

예:

```text
Pending
- 병원 예약
- 저녁 약속
- 준비물
```

Caller:

```text
"병원 예약은 취소했어요."
```

재계산:

```text
Pending
- 병원 예약 → 제거
- 저녁 약속
- 준비물
```

이 상태는 Realtime 모델에만 의존하지 않고 Jarvis Agent 쪽에서 관리 가능한 구조를 고려한다.

---

# 20. Echo / Feedback 방지

Virtual Audio TX와 Phone.app RX capture 조합에서 다음을 측정한다.

- TX → RX loopback 발생 여부
- level
- delay
- simultaneous speech 상태
- feedback 가능성

우선순위:

1. RX/TX logical path 분리
2. process-specific RX capture
3. virtual input routing
4. 필요 시 echo cancellation
5. TX playback timestamp 관리

---

# 21. 녹음

모든 Jarvis 개입 통화는 Mac에서 녹음 가능하도록 한다.

실시간 processing은 PCM을 사용할 수 있다.

장기 저장 포맷은 WAV를 기본으로 사용하지 않는다.

최종 파일:

```text
AAC + M4A
```

## 21.1 RX

```text
rx.m4a
```

실제 Caller audio.

## 21.2 TX

```text
tx.m4a
```

Jarvis가 생성한 audio 중 실제 TX path에 전달한 stream.

TX audio는 Call Bridge가 자체 생성/수신하므로 별도 녹음이 가능해야 한다.

---

# 22. Merged Recording

통화 종료 후 Mac에서:

```text
rx.m4a
+
tx.m4a
↓
merged.m4a
```

를 생성한다.

Merge는 Cloudflare Worker에서 수행하지 않는다.

이유:

- Worker CPU 사용 불필요
- Mac native audio framework 사용 가능
- RX/TX timing 정보 활용 가능
- 서버 비용/복잡도 감소

---

# 23. Transcript

Mixed recording에 diarization을 기본 적용하지 않는다.

RX/TX가 분리되므로:

```text
RX = Caller
TX = Jarvis
```

로 화자를 결정한다.

예:

```json
[
  {
    "speaker": "caller",
    "startMs": 1200,
    "endMs": 3400,
    "text": "내일 오후에는 어려울 것 같습니다."
  },
  {
    "speaker": "jarvis",
    "startMs": 3700,
    "endMs": 5200,
    "text": "그러면 수요일 오후는 어떠신가요?"
  }
]
```

Caller transcript:

- Realtime input transcription 또는 별도 STT

Jarvis transcript:

- 생성 text
- 실제 playback 완료 구간 기준

Mixed audio diarization은 fallback일 뿐 기본 구조가 아니다.

---

# 24. Local Recording Storage

PoC local directory:

```text
~/Library/Application Support/JarvisCallBridge/
└─ calls/
   └─ {callId}/
      ├─ rx.m4a
      ├─ tx.m4a
      ├─ merged.m4a
      └─ metadata.json
```

R2 upload 성공 후에도 PoC에서는 즉시 삭제하지 않는다.

자동 삭제/retention 정책은 후속 범위다.

---

# 25. R2 Upload

권장 흐름:

```text
1. 통화/Bridge Session 시작
   Call Bridge → Jarvis API

2. call_id 생성

3. 통화 진행

4. 통화 종료

5. Mac에서 RX/TX M4A finalize

6. Mac에서 merged.m4a 생성

7. RX/TX/Merged → R2 직접 업로드

8. Call Bridge → Jarvis complete API

9. SQLite metadata 저장
```

큰 바이너리를 Worker가 중계하는 구조를 기본으로 하지 않는다.

Call Bridge에는 permanent R2 secret을 하드코딩하지 않는다.

Jarvis API가 안전한 upload authorization 또는 signed upload 정보를 발급하는 구조를 사용한다.

---

# 26. Jarvis Call API

기존 `api/`에 Call 관련 endpoint를 추가한다.

## 26.1 Call/Bridge Session 시작

```text
POST /api/calls
```

목적:

- call_id 생성
- Agent/User context 확인
- metadata 초기화
- R2 object path 결정
- upload authorization 준비

예:

```json
{
  "callId": "call_xxx",
  "recordingKeys": {
    "rx": "calls/call_xxx/rx.m4a",
    "tx": "calls/call_xxx/tx.m4a",
    "merged": "calls/call_xxx/merged.m4a"
  }
}
```

## 26.2 Call 완료

```text
POST /api/calls/{callId}/complete
```

예:

```json
{
  "direction": "inbound",
  "phoneNumber": "01012345678",
  "startedAt": "2026-08-15T12:00:00Z",
  "endedAt": "2026-08-15T12:05:12Z",
  "durationSeconds": 312,
  "recordings": {
    "rx": "calls/call_xxx/rx.m4a",
    "tx": "calls/call_xxx/tx.m4a",
    "merged": "calls/call_xxx/merged.m4a"
  },
  "transcript": []
}
```

---

# 27. SQLite Call Metadata

녹음 파일 자체를 SQLite에 저장하지 않는다.

SQLite에는 기능 수행에 필요한 metadata만 저장한다.

예:

```text
calls
------------------------------------------------
id
direction
phone_number
started_at
ended_at
duration_seconds
status

rx_r2_key
tx_r2_key
merged_r2_key

transcript
summary

created_at
updated_at
```

현재 개인용 PoC이므로 다음 서비스 운영 데이터는 추가하지 않는다.

- 요금제
- billing
- 월별 quota
- 사용자별 과금 집계
- 결제 이력
- SaaS usage analytics

기존 Jarvis SQLite convention을 우선한다.

---

# 28. Call Summary

통화 종료 후 Call Bridge가 직접 LLM summary를 만들지 않는다.

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
ABC 병원

내용:
내일 오후 2시 예약 확인 전화.

결과:
예약 변경 없음.

Action:
없음.
```

---

# 29. Jarvis Tool 연동

Call Bridge에서 Gmail/Calendar 등의 business tool을 다시 구현하지 않는다.

전화 중 필요한 Tool은 기존 Jarvis Agent를 이용한다.

예:

```text
Caller:
"수요일 오후 3시 가능하세요?"

Jarvis
→ Calendar Tool
→ 일정 확인
→ Realtime response
→ Caller
```

기존 기능:

- Memory
- Gmail
- Google Calendar
- Web Search
- Approval
- Scheduler

---

# 30. Approval

기존 Jarvis Approval 정책을 유지한다.

전화라는 이유로 write Tool approval을 우회하지 않는다.

PoC에서는:

- read Tool 우선
- write Tool은 pending approval 생성
- Admin에서 승인

정도로 제한할 수 있다.

---

# 31. 인증

Call Bridge는 Jarvis API와 인증된 연결을 사용한다.

```text
Call Bridge
↓
Authentication Token
↓
Jarvis API
↓
User Agent Instance
↓
User SQLite
```

Mac credential:

- Keychain 저장
- source code 하드코딩 금지

Realtime provider secret:

- 가능하면 Mac에 permanent secret 저장 금지
- server-issued ephemeral credential 또는 안전한 server-side proxy/token flow 우선

---

# 32. 장애 처리

## 32.1 Realtime/Cloud 실패

AI 개입만 중단한다.

가능하면 일반 Phone.app/iPhone 통화 자체에는 영향을 주지 않는다.

## 32.2 Virtual Audio Device 실패

- AI TX 중단
- 일반 microphone로 자동 복구 가능한지 후속 검토
- PoC에서는 사용자에게 명확한 오류 표시

## 32.3 RX Capture 실패

AI 자동 응답을 중단한다.

상대방 음성을 확보하지 못한 상태에서 임의 응답하지 않는다.

## 32.4 R2 Upload 실패

local recording을 유지한다.

재업로드 가능 상태로 표시한다.

## 32.5 Merge 실패

RX/TX 원본을 유지한다.

Merged 파일만 재생성한다.

## 32.6 Call-state 감지 실패

PoC에서는 Manual Bridge Mode로 전환할 수 있다.

---

# 33. Local Logging

기록 대상 예:

```text
[PHONE] process found
[CALL] state=manual/idle/ringing/active
[RX] source=Phone.app
[RX] capture method=ScreenCaptureKit/CoreAudioTap
[RX] stream started
[RX] first caller buffer received
[RX] format=...
[TX] virtual device ready
[TX] Phone.app input selected/manual
[TX] test audio started
[TX] test audio completed
[AUDIO] separation test...
[AUDIO] feedback level...
[REALTIME] connected
[REALTIME] speech_started
[REALTIME] response cancelled
[RECORD] started
[RECORD] finalized
[MERGE] completed
[R2] upload success/failure
[API] complete success/failure
```

Secret과 원문 audio data를 일반 로그에 출력하지 않는다.

---

# 34. 개발 위치

현재 Jarvis repository의 최상위 구조는 다음으로 고정한다.

```text
jarvis/
├─ admin/
├─ api/
├─ bridge/
├─ docs/
└─ web/
```

Call Bridge Client 코드는 **`bridge/`에 직접 작성한다.**

다음 경로를 새로 만들지 않는다.

```text
bridge/call-bridge/
swift/
mac/
desktop/
callbridge/
```

`bridge/`는 macOS Call Bridge app project 전체 소스의 root다.

---

# 35. 개발 Phase

## CB Phase 0 — macOS 26 Phone.app Feasibility

목적:

**실제 iPhone 셀룰러 통화에서 Phone.app 기반 RX/TX audio bridge가 성립하는지 증명한다.**

기존 Phase 0의 direct API 조사 결과는 참고자료로 유지한다.

### CB Phase 0-A — Phone.app RX Spike

검증:

- 실제 Phone.app 수신 통화
- Phone.app process identification
- ScreenCaptureKit app audio
- Core Audio process tap
- 실제 Caller voice buffer 수신
- latency / format
- 반복 통화 안정성

완료 기준:

```text
실제 Caller speech
↓
Phone.app
↓
Call Bridge RX buffer
```

가 실제 기기에서 확인된다.

### CB Phase 0-B — Virtual Audio TX Spike

검증:

- virtual audio input device 가능성
- AudioDriverKit / 공식 Core Audio driver 방식
- Call Bridge test PCM 전달
- Phone.app microphone/input으로 선택
- 실제 Caller가 test audio 청취
- Mac speaker acoustic leakage가 아닌지 검증

완료 기준:

```text
Call Bridge Test Audio
↓
Virtual Input
↓
Phone.app
↓
iPhone
↓
실제 Caller
```

가 실제 통화에서 확인된다.

### CB Phase 0-C — Separation / Lifecycle Spike

검증:

- RX/TX 동시 동작
- TX → RX feedback
- simultaneous speech
- basic latency
- call-state detection 후보
- manual start/stop fallback
- cleanup / second-call repeat

### Phase 0 Gate

#### PASS

다음이 모두 실제 통화에서 확인:

- RX Caller audio 확보
- TX audio 실제 Caller 전달
- RX/TX 동시 사용 가능
- 후속 실시간 AI 구현에 사용할 수 있는 latency/안정성

자동 Call State가 미완성이어도 manual lifecycle이 안정적이면 조건부 판단 가능하다.

#### CONDITIONAL PASS

핵심 RX/TX 양방향 audio bridge는 성공했지만:

- 자동 call detection이 없음
- input device 수동 선택 필요
- 설치/권한 단계가 필요
- 일부 echo 처리 필요

등의 제약이 존재한다.

이 경우 Phase 1 진행 가능하되 제약을 문서화한다.

#### FAIL

다음 중 하나면 실패:

- 실제 Caller RX를 확보할 유지보수 가능한 방법이 없음
- Jarvis/Test TX를 실제 Caller에게 전달할 유지보수 가능한 방법이 없음
- RX/TX 동시 사용이 불가능
- virtual audio path가 실사용 불가능한 수준으로 불안정
- private/undocumented mechanism 없이는 핵심 audio path를 구성할 수 없음

Direct Continuity API가 없다는 이유만으로 FAIL 처리하지 않는다.

---

## CB Phase 1 — Local Audio Bridge

Phase 0에서 검증된 방식을 정식 local bridge component로 만든다.

구현:

- RX abstraction
- TX abstraction
- Virtual Audio Device integration
- Audio Router
- lifecycle
- manual/automatic call state
- cleanup
- minimal SwiftUI
- local logs

완료 기준:

실제 통화에서 반복적으로:

```text
Caller RX
↔
Call Bridge
↔
Test TX
```

가 안정적으로 동작한다.

---

## CB Phase 2 — Realtime AI / Barge-in

구현:

- Realtime Voice connection
- RX streaming
- AI TX streaming
- VAD
- turn detection
- speech_started
- barge-in
- response cancel
- TX buffer clear
- context truncate
- pending speech intent

완료 기준:

Caller가 Jarvis 발화 중 말을 시작하면:

```text
Jarvis 즉시 STOP
↓
Caller 발화 수신
↓
새 context 반영
↓
자연스럽게 재응답
```

이 실제 전화에서 동작한다.

---

## CB Phase 3 — Jarvis Agent Integration

구현:

- Jarvis authentication
- existing Agent 연결
- Memory
- Tool Calling
- Calendar read 등 기존 Tool
- call session context
- Approval 연계

완료 기준:

실제 전화 중 기존 Jarvis Memory 및 최소 1개 Tool을 사용할 수 있다.

---

## CB Phase 4 — Recording

구현:

- RX recording
- TX recording
- AAC/M4A
- timestamp/timeline sync
- local merge
- merged.m4a
- local metadata

완료 기준:

```text
rx.m4a
tx.m4a
merged.m4a
metadata.json
```

이 실제 통화 후 정상 생성되고 재생 가능하다.

---

## CB Phase 5 — R2 / Call API / SQLite

구현:

- `POST /api/calls`
- secure R2 upload flow
- RX/TX/Merged upload
- `POST /api/calls/{id}/complete`
- SQLite call metadata
- transcript
- summary
- Admin에서 최소 Call History 조회/재생

완료 기준:

통화가 종료되면 local → R2 → SQLite metadata까지 end-to-end 저장된다.

---

## CB Phase 6 — App Hardening / DMG

구현:

- signed macOS `.app`
- permission onboarding
- Virtual Audio Device installation/onboarding
- error recovery
- app launch/relaunch
- login/startup 옵션 검토
- Developer ID signing
- notarization
- DMG packaging

최종 배포 형태:

```text
Jarvis Call Bridge.app
↓
Signed / Notarized
↓
Jarvis-Call-Bridge.dmg
```

PoC 기능 검증이 완료되기 전에는 Phase 6을 선행하지 않는다.

---

# 36. 1차 PoC 제외 범위

- Twilio
- SIP
- BYOC
- 별도 전화번호
- Android
- iPhone Jarvis App
- Apple Watch
- Multi-user SaaS
- Mac 1대에서 여러 사용자
- 멀티 Call Bridge
- Vector DB
- RAG
- Local LLM
- Billing
- 요금제
- 사용량 제한
- 결제
- 통신사 API
- 자동 recording retention
- DTMF / IVR
- 고급 call transfer
- production-grade auto updater

---

# 37. 비기능 요구사항

## 37.1 성능

- audio realtime thread에서 blocking I/O 금지
- RX → Realtime latency 최소화
- Realtime → TX latency 최소화
- recording encode는 realtime routing과 분리
- R2 upload는 통화 종료 후 background 처리

## 37.2 Mac 부하

Mac 부하를 최소화한다.

- Local LLM 사용 금지
- Apple native audio framework 우선
- AAC/M4A native encoder 우선
- audio merge는 Mac local
- Worker에서 merge하지 않음
- 필요 이상의 audio re-encoding 최소화

## 37.3 안정성

- AI 실패가 기본 전화 통화를 종료시키지 않아야 함
- recording 실패가 통화를 종료시키지 않아야 함
- R2 실패 시 local copy 유지
- Virtual Input 실패 시 명확한 상태 표시
- 다음 통화에서 resource 재사용 가능

## 37.4 보안

- Jarvis token → Keychain
- R2 permanent credential → 앱 하드코딩 금지
- Realtime permanent API secret → 앱 하드코딩 금지
- macOS permission은 목적을 명확히 표시
- 사용하지 않는 권한 요구 금지

---

# 38. 성공 기준

## Continuity / Phone.app

- 기존 iPhone 셀룰러 번호 유지
- Phone.app에서 실제 수신/발신 가능
- Caller RX 확보
- Jarvis/Test TX 실제 전달
- RX/TX 동시 동작

## Realtime AI

- Caller speech realtime processing
- AI realtime TX
- barge-in
- 즉시 output stop
- 자연스러운 turn-taking

## Jarvis

- 기존 Memory 사용
- 기존 Tool 최소 1개 사용
- existing Agent state 이용

## Recording

- RX M4A
- TX M4A
- Merged M4A
- transcript
- playback

## Cloud

- R2 upload
- SQLite metadata
- recording object key
- transcript
- summary

## App

- stable `.app`
- 최종 DMG 생성 가능

---

# 39. PoC 중단 조건

다음 조건에서는 후속 Phase를 억지로 진행하지 않는다.

1. Phone.app 실제 Caller RX를 안정적으로 확보할 방법이 없음
2. Virtual Audio Input 또는 이에 준하는 공개/유지보수 가능한 TX path가 실제 통화에서 동작하지 않음
3. RX/TX 동시 사용이 불가능함
4. latency 또는 feedback이 Realtime conversation에 사용할 수 없는 수준
5. 핵심 기능이 private/undocumented API에 과도하게 의존해야 함

다만 다음만으로 중단하지 않는다.

```text
CXCallObserver가 macOS에서 unavailable
Direct Continuity TX API가 없음
자동 call state callback이 없음
```

핵심 양방향 audio path가 다른 유지보수 가능한 공개 방식으로 구현 가능하면 계속 진행한다.

---

# 40. Phase 0 조사 결과 보존

기존 `Call_Bridge_Phase_0_Feasibility_Report.md`는 삭제하지 않는다.

해당 문서는 다음 사실을 증명한 1차 조사 결과로 유지한다.

- direct native macOS CallKit path의 한계
- FaceTime/ScreenCaptureKit RX 후보
- direct TX injection public API 부재
- Virtual Audio Device 미검증 상태

v1.1의 Phase 0 재검증 결과는 별도 보고서로 작성한다.

권장 파일명:

```text
Call_Bridge_Phase_0_PhoneApp_Feasibility_Report.md
```

---

# 41. 개발 우선순위

```text
CB Phase 0-A
Phone.app RX Spike
        ↓
CB Phase 0-B
Virtual Audio TX Spike
        ↓
CB Phase 0-C
RX/TX Separation + Lifecycle
        ↓
Phase 0 PASS / CONDITIONAL PASS / FAIL
        ↓
CB Phase 1
Local Audio Bridge
        ↓
CB Phase 2
Realtime AI / Barge-in
        ↓
CB Phase 3
Jarvis Agent Integration
        ↓
CB Phase 4
RX/TX/Merged Recording
        ↓
CB Phase 5
R2 + Call API + SQLite
        ↓
CB Phase 6
App Hardening + DMG
```

가장 중요한 원칙:

**직접 Continuity API의 존재 여부가 아니라, macOS 26+ Phone.app을 중심으로 실제 Caller RX와 Jarvis TX를 유지보수 가능한 방식으로 양방향 연결할 수 있는지가 Call Bridge의 핵심 성공 기준이다.**

---

# 42. 참고 근거

## 프로젝트 내부

- `Call_Bridge_Phase_0_Feasibility_Report.md`
  - direct CallKit / TX path 조사 결과
  - ScreenCaptureKit RX 후보
  - Virtual Audio Device 후속 검증 필요성

## Apple 공식 문서

- Make and receive phone calls on Mac, iPad, and Apple Vision Pro
  - https://support.apple.com/en-us/102405
- ScreenCaptureKit
  - https://developer.apple.com/documentation/screencapturekit/
- Capturing system audio with Core Audio taps
  - https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
- AudioDriverKit
  - https://developer.apple.com/documentation/audiodriverkit/
- Creating an Audio Server Driver Plug-in
  - https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in
