# Bridge Realtime 통화 프롬프트 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bridge 앱에서 존댓말/반말과 추가 프롬프트를 저장하고, 다음 착신 Realtime `session.update.instructions`에 적용한다.

**Architecture:** 순수 `compose` + UserDefaults 저장. 연결 순간 `makeAdapter`가 조합문을 adapter에 넣는다. VAD/PCM은 그대로다. 통화 중 재전송 없음.

**Tech Stack:** Swift 6, SwiftUI, UserDefaults, XCTest.

**스펙:** `docs/superpowers/specs/2026-08-24-bridge-realtime-call-prompt-design.md`

**바꾸면 안 되는 것:** PCM/mute/barge-in, session.update VAD, Admin 동기화, 통화 중 두 번째 session.update, 드라이버.

작업 디렉터리: `/Volumes/Dev/workspaces/twms/jarvis`  
커밋은 사용자가 요청할 때만 한다.

## File map

| 파일 | 역할 |
|---|---|
| `bridge/Sources/JarvisCallBridge/Realtime/RealtimeCallInstructions.swift` | 말투 enum, 조합, UserDefaults 저장 |
| `bridge/Tests/JarvisCallBridgeTests/RealtimeCallInstructionsTests.swift` | 조합·저장·로그 안전 |
| `bridge/Sources/JarvisCallBridge/Realtime/OpenAIRealtimeVoiceAdapter.swift` | 기존 `instructions` 유지 |
| `bridge/Tests/JarvisCallBridgeTests/OpenAIRealtimeVoiceAdapterTests.swift` | 주입 instructions 단언 추가 |
| `bridge/Sources/JarvisCallBridge/Realtime/OpenAIRealtimeVoiceSessionController.swift` | connect 시 조합문 로드 + 로그 |
| `bridge/Sources/JarvisCallBridge/App/BridgeViewModel.swift` | UI 상태 ↔ 저장 |
| `bridge/Sources/JarvisCallBridge/UI/ContentView.swift` | 말투 + 추가 프롬프트 |

---

### Task 1: 조합 + 저장 (TDD)

**Files:**
- Create: `bridge/Sources/JarvisCallBridge/Realtime/RealtimeCallInstructions.swift`
- Test: `bridge/Tests/JarvisCallBridgeTests/RealtimeCallInstructionsTests.swift`

- [ ] **Step 1:** 실패하는 조합 테스트를 작성한다.

- [ ] **Step 2:** `swift test --filter RealtimeCallInstructionsTests`가 실패하는지 확인한다.

- [ ] **Step 3:** `RealtimeSpeechStyle`, `compose`, UserDefaults store를 최소 구현한다.

- [ ] **Step 4:** 테스트를 통과시킨다.

---

### Task 2: adapter + connect 배선 (TDD)

**Files:**
- Modify: `OpenAIRealtimeVoiceAdapter.swift` (기본문 유지)
- Modify: `OpenAIRealtimeVoiceSessionController.swift` (`loadInstructions`)
- Modify: `OpenAIRealtimeVoiceAdapterTests.swift`
- Modify: `BridgeViewModel.swift`, `ContentView.swift`

- [ ] **Step 1:** 주입 instructions가 `session.update`에 들어가는 테스트를 추가한다.

- [ ] **Step 2:** 기본 `makeAdapter`가 store 조합문을 넣게 한다. connect 로그는 `style=` / `extra=`만.

- [ ] **Step 3:** ViewModel + ContentView에 말투/추가 프롬프트를 붙인다.

- [ ] **Step 4:** `swift test --filter 'RealtimeCallInstructionsTests|OpenAIRealtimeVoiceAdapterTests'` 후 `./Scripts/build-app.sh`.
