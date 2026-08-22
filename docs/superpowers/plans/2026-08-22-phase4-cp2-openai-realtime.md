# Phase 4 CHECKPOINT 2 — OpenAI Realtime Implementation Plan

상태: **COMPLETE / FINAL PASS** (2026-08-22). 실기기 한 턴과 자동화 368 passed는 `docs/Call_Bridge_v2_Phase_4_Report.md`에 기록. 이 문서는 구현 당시 작업 목록이며 새 작업을 여기서 이어 하지 않는다.

**Goal:** 토글 ON + Active + PCM Running일 때만 OpenAI Realtime에 붙어 한 턴 speech-to-speech를 실통화로 확인한다.

**Architecture:** CP1 adapter·변환기·세션 순서를 재사용한다. 앱 기본 세션은 `OpenAIRealtimeVoiceSessionController`다. `.env` 키로 `URLSession` WebSocket을 연다. Capture RX는 새 제어면 링에서 읽고 24 kHz PCM16으로 보낸다. 받은 오디오는 약 200 ms 워터마크만 TX 링에 넣는다. 테스트는 mock/가짜 transport만 쓴다.

**Tech Stack:** Swift 6 / SwiftPM (`bridge/`), C11 atomics (`JarvisPCMRealtime`), `URLSessionWebSocketTask`, XCTest. 새 서드파티 없음. 드라이버 수정 없음.

**스펙:** `docs/superpowers/specs/2026-08-22-phase4-cp2-openai-realtime-design.md`

작업 디렉터리: `/Volumes/Dev/workspaces/twms/jarvis`  
테스트: `cd bridge && swift test --filter <TestClass>`

**바꾸면 안 되는 것:** disconnect → pcm.stop 순서, Realtime 실패로 route 롤백 금지, Ringing에서 PCM/Realtime 금지, 드라이버/070/SIP/Jarvis Agent.

---

## File map

| 파일 | 역할 |
|---|---|
| `.gitignore` | `bridge/.env` |
| `bridge/.env.example` | 키 이름만 |
| `docs/Call_Bridge_v2_Phase_4_Report.md` | CP2 IN PROGRESS |
| `Realtime/RealtimeEnvFile.swift` | `.env` 파서 + 번들 옆 경로 |
| `JarvisPCMRealtime.h/.c` | RX 소비 링, overflow, Read/Clear |
| `Realtime/RealtimeDebugWAVWriter.swift` | 24 kHz mono PCM16 WAV |
| `Realtime/RealtimeVoiceUIState.swift` | Idle/Armed/Connecting/Connected/Failed |
| `Realtime/OpenAIRealtimeVoiceAdapter.swift` | WebSocket + 이벤트 |
| `Realtime/OpenAIRealtimeVoiceSessionController.swift` | 토글, 펌프, WAV |
| `SystemCallAudioPCMController.swift` | ReadRX / WriteTX / ClearRX / queued TX |
| `BridgeViewModel.swift` | 토글, 세션 주입, 중간 연결 |
| `ContentView.swift` | Realtime 줄 + 토글 |
| 테스트 파일 6개 | env, RX 링, WAV, adapter JSON, 세션 토글, UI |

---

### Task 1: 문서·gitignore·example

**Files:**
- Modify: `.gitignore`
- Create: `bridge/.env.example`
- Modify: `docs/Call_Bridge_v2_Phase_4_Report.md`

- [ ] **Step 1:** `.gitignore`에 `bridge/.env` 추가. `bridge/.env.example` 작성 (`OPENAI_API_KEY=`, `OPENAI_REALTIME_MODEL=gpt-realtime-2.1-mini`). 리포트 헤더를 CP2 IN PROGRESS로, 본 스펙/플랜 경로를 적는다.

- [ ] **Step 2: Commit**

```bash
git add .gitignore bridge/.env.example docs/Call_Bridge_v2_Phase_4_Report.md
git commit -m "docs: open Phase 4 CP2 and ignore bridge/.env"
```

---

### Task 2: `.env` 로더 (TDD)

**Files:**
- Test: `bridge/Tests/JarvisCallBridgeTests/RealtimeEnvFileTests.swift`
- Create: `bridge/Sources/JarvisCallBridge/Realtime/RealtimeEnvFile.swift`

- [ ] **Step 1: 실패하는 테스트**

없는 파일 → nil. `OPENAI_API_KEY=sk-test` → 키. `#` 주석/빈 줄 무시. 따옴표 벗김. 빈 값 → nil. `OPENAI_REALTIME_MODEL` 선택. `bundleURL`이 `.../bridge/.build/App.app`이면 `.env`는 `.../bridge/.env`.

- [ ] **Step 2:** `swift test --filter RealtimeEnvFileTests` → FAIL (타입 없음)

- [ ] **Step 3:** `RealtimeEnvFile.load(from: URL)`, `loadFromProcess()`, `envFileURL(appBundleURL:)`

- [ ] **Step 4:** 테스트 PASS 후 커밋 `feat: load OpenAI keys from bridge/.env`

---

### Task 3: RX 소비 링 (TDD)

**Files:**
- Test: `bridge/Tests/JarvisCallBridgeTests/SystemCallAudioPCMControllerComputationTests.swift` (추가)
- Modify: `JarvisPCMRealtime.h`, `JarvisPCMRealtime.c`

- [ ] **Step 1: 실패하는 테스트**

`PublishRXFrames` 후 `ReadRXFrames`가 같은 인터리브 샘플을 반환. 빈 링은 0. 용량을 넘기면 새 프레임을 버리고 `rxOverflowCount`가 오른다. `ClearRX` 후 읽으면 0. Capture IOProc도 링에 넣는다.

- [ ] **Step 2:** 테스트 FAIL (심볼 없음)

- [ ] **Step 3:** TX 링과 같은 SPSC. `PublishRXInterleaved`가 메트릭 후 링에 쓴다. 공간 부족 시 못 넣은 프레임만 overflow. `Reset`에서 `ClearRX`.

- [ ] **Step 4:** PASS 후 커밋 `feat: add control-plane RX consume ring`

---

### Task 4: 디버그 WAV (TDD)

**Files:**
- Test: `bridge/Tests/JarvisCallBridgeTests/RealtimeDebugWAVWriterTests.swift`
- Create: `bridge/Sources/JarvisCallBridge/Realtime/RealtimeDebugWAVWriter.swift`

- [ ] **Step 1:** 임시 디렉터리에 24 kHz mono PCM16 4샘플을 쓰고 닫으면 RIFF/WAVE/fmt/data와 little-endian 샘플이 맞는지.

- [ ] **Step 2–4:** 구현, PASS, 커밋 `feat: write 24 kHz PCM16 debug WAV files`

---

### Task 5: OpenAI adapter (가짜 transport, TDD)

**Files:**
- Test: `bridge/Tests/JarvisCallBridgeTests/OpenAIRealtimeVoiceAdapterTests.swift`
- Create: `bridge/Sources/JarvisCallBridge/Realtime/RealtimeWebSocketTransporting.swift`
- Create: `bridge/Sources/JarvisCallBridge/Realtime/OpenAIRealtimeVoiceAdapter.swift`

- [ ] **Step 1: 실패하는 테스트**

가짜 transport: `connect` 성공 후 보낸 첫 메시지가 `session.update`이고 instructions/모델/pcm16 24k가 들어 있다. `sendRX`가 `input_audio_buffer.append` + base64 PCM16. 스크립트된 `response.output_audio.delta` / `response.audio.delta`를 `pollTX`가 디코드한다. `failConnect`면 false. 네트워크 없음.

- [ ] **Step 2–4:** 구현. URL: `wss://api.openai.com/v1/realtime?model=`. Header: `Authorization: Bearer`. `session.update`에 고정 한국어 지시문. 커밋 `feat: add OpenAI Realtime adapter with injectable transport`

---

### Task 6: 세션 컨트롤러 토글·펌프 (TDD)

**Files:**
- Test: `bridge/Tests/JarvisCallBridgeTests/OpenAIRealtimeVoiceSessionControllerTests.swift`
- Create: `bridge/Sources/JarvisCallBridge/Realtime/RealtimeVoiceUIState.swift`
- Create: `bridge/Sources/JarvisCallBridge/Realtime/OpenAIRealtimeVoiceSessionController.swift`
- Create: `bridge/Sources/JarvisCallBridge/Realtime/RealtimePCMBuffering.swift`
- Modify: `SystemCallAudioPCMController.swift` (버퍼 API)
- Modify: `CallAudioPCMControllingSpy`는 이 프로토콜을 구현하지 않아도 됨

- [ ] **Step 1: 실패하는 테스트** (메모리 PCM 더블 + mock adapter)

토글 OFF + `connect` → adapter.connect 0회, UI `idle`.  
토글 ON + PCM running + `connect` → adapter.connect 1회, UI `connected`.  
adapter false → UI `failed`, PCM 더블은 계속 running.  
토글 OFF `disconnect` → adapter.disconnect, WAV 닫힘, PCM stop 없음.  
RX 더블에 48k 스테레오를 넣으면 `sendRX`가 24k PCM16을 받는다.  
`enqueueTX` 후 펌프가 `WriteTXFrames`를 호출하고 queued가 9600을 넘지 않게 자른다.

- [ ] **Step 2–4:** 구현. 앱 기본값을 이 컨트롤러로. 테스트 `CallAudioSessionController`는 계속 스파이. 커밋 `feat: connect Realtime only when toggle is on`

---

### Task 7: UI·ViewModel 연결

**Files:**
- Test: `bridge/Tests/JarvisCallBridgeTests/BridgeViewModelPhase3Tests.swift` 또는 신규 `RealtimeToggleUITests.swift`
- Modify: `BridgeViewModel.swift`, `ContentView.swift`

- [ ] **Step 1:** 시작 시 토글 OFF / `Idle`. `setRealtimeEnabled(true)` → `Armed` (PCM 없으면 connect 없음). PCM running 스파이에서 ON이면 connect.

- [ ] **Step 2–4:** ContentView Realtime 줄에 Toggle + 상태 텍스트. 커밋 `feat: add Realtime toggle that resets off at launch`

---

### Task 8: 전체 검증

- [ ] `cd bridge && swift test` — 기존 346 + 신규 전부 PASS
- [ ] 리포트에 자동화 통과 수를 적는다
- [ ] 커밋 `test: record Phase 4 CP2 automated coverage`

실기기는 사용자가 한다. 에이전트는 전화/OpenAI 실연결을 하지 않는다.
