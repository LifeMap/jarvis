# CB v2 Phase 1 Report — Dual Loopback Audio Driver

작성일: 2026-08-15
최종 판정 (에이전트 단계): **IMPLEMENTATION/BUILD/SELFTEST COMPLETE — MANUAL DRIVER INSTALL REQUIRED**

## Environment

| 항목 | 값 |
|---|---|
| macOS | 26.6 (Build 25G72) |
| Architecture | arm64 (Apple Silicon) — 이번 세션에서는 arm64만 빌드/검증했다. Universal(arm64+x86_64) binary는 PRD §21이 명시적으로 선택 사항으로 남겨둔 항목이며, Phase 1 구조를 복잡하게 만들지 않기 위해 이번에는 시도하지 않고 후속 Phase로 미룬다. |
| Swift | Apple Swift 6.3.3 (swift-driver 1.148.6) |
| Xcode | 26.6 (Build 17F113) |

## Phase 0 Gate

- Phase 0 result: **CONDITIONAL PASS** (`docs/Call_Bridge_v2_Phase_0_Report.md` §Real Device Validation 참고)
- 실제 착신 검증 요약: Work Mode OFF/ON(ARMED) 모두에서 Mac Studio Phone.app 착신 정상, ARMED 상태에서 여러 차례 반복 착신 정상, audio route 변경 없음, v1의 "Bridge 활성화 시 착신 사라짐" 현상 재현 안 됨. 다만 PRD가 요구한 10회 연속 테스트를 전부 채우지는 않아 무조건 PASS로 과장하지 않고 CONDITIONAL PASS로 유지.

## Scope

### Implemented

- `JarvisCallAudio.driver` — 순수 C, `AudioServerPlugIn.h` 공개 API 기반, Xcode 프로젝트/DriverKit 불필요
- **Jarvis Call Capture** / **Jarvis Call Inject** — 각각 독립된 Device(Output stream + Input stream)
- Output→Input **intra-process loopback** (동일 디바이스 내부, Bridge↔Driver 커스텀 IPC 없음 — 표준 CoreAudio Device I/O만 사용)
- 두 디바이스가 완전히 분리된 `JarvisLoopbackBuffer` 인스턴스를 각자 소유(cross-device contamination 구조적으로 불가능)
- Lifecycle/control: 정적 생성 + hidden/active custom property(`Ract`)로 토글, `Rclr`로 buffer 초기화
- **안전장치**: `DeviceCanBeDefaultDevice`/`DeviceCanBeDefaultSystemDevice`를 항상 false로 응답 — 설치/활성화만으로 macOS 기본 입출력이 바뀌는 것을 HAL contract 레벨에서 원천 차단
- `JarvisAudioDriverTool` 진단 CLI (`status`/`list`/`activate`/`deactivate`/`clear`/`test-capture`/`test-inject`/`test-isolation`/`stress`)
- `Scripts/build-driver.sh`, `install-driver.sh`, `uninstall-driver.sh` (exact-path만 대상, wildcard 없음)
- In-process self-test (`AudioDriver/Plugin/selftest.c`, coreaudiod/sudo 불필요)
- 자동 테스트: `JarvisLoopbackBuffer` 순수 로직 5건 + `BridgeStateMachine`이 driver를 activate하지 않음을 증명하는 spy 테스트 1건 추가
- 앱 UI에 "Call Audio Driver" 상태 행 추가 (Not Installed/Installed-Inactive/Active/Error, 읽기 전용 폴링)

### Not Implemented (계획대로 구현하지 않음)

Phone.app routing, 실제 call RX/TX, auto answer, Realtime AI, recording, Human Takeover, iPhone Handoff, Jarvis API Tool Calls, R2, SIP/070/Twilio, macOS Default Input/Output/System Output 변경(코드상 setter 자체가 없음), Work Mode에 의한 driver 자동 activate.

## Driver Architecture

```
JarvisCallAudio.driver
├─ Jarvis Call Capture (Device 2)
│  ├─ Output Stream (3) ──┐
│  └─ Input Stream (4)  ◄─┘  JarvisLoopbackBuffer #1 (own instance)
│
└─ Jarvis Call Inject (Device 5)
   ├─ Output Stream (6) ──┐
   └─ Input Stream (7)  ◄─┘  JarvisLoopbackBuffer #2 (own instance, never shared with #1)
```

`DoIOOperation`의 `kAudioServerPlugInIOOperationWriteMix`(Output)가 그 디바이스의 ring buffer에 쓰고, `kAudioServerPlugInIOOperationReadInput`(Input)이 같은 ring buffer에서 읽는다 — 이것이 loopback의 전부다. 외부에서 이 디바이스를 사용하는 쪽(향후 Bridge 앱, 지금은 `JarvisAudioDriverTool`)은 표준 `AudioDeviceCreateIOProcIDWithBlock`/`AudioDeviceStart`로 여느 CoreAudio 장치와 동일하게 접근한다.

## Audio Format

- Sample rate: 48000 Hz (고정, `AvailableNominalSampleRates`도 동일 값 하나만 보고)
- Channels: 2 in / 2 out
- Format: Float32, packed, native endian, interleaved
- Interleaving 선택 이유: 구현 단순성 — `AudioBufferList`가 버퍼 1개만 가지므로 property 코드와 IO 코드 양쪽에서 non-interleaved 대비 분기 없이 처리 가능

## Buffer Design

- `AudioDriver/Shared/include/JarvisLoopbackBuffer.h` — CoreAudio와 완전히 독립적인 순수 C 링버퍼, 디바이스당 1초(48000 frame) 용량
- Underrun 정책: 부족분은 무음(0)으로 채움, `underrunCount` 증가
- Overrun 정책: 가장 오래된 프레임부터 버림(reader가 최신 capacityFrames로 재동기화), `overrunFrameCount` 증가 — deterministic, 코드와 이 보고서 양쪽에 기록
- Reset: `Rclr` 커스텀 property 또는 `Ract=1`로의 전이 시 buffer 전체를 0으로 memset하고 인덱스/카운터를 초기화 — 재시작 시 이전 세션의 stale audio가 재생되지 않도록 보장
- Realtime 안전성: `Init`(malloc, 1회, 실시간 컨텍스트 밖)과 `Write`/`Read`(포인터 연산만, 할당/락/블로킹 없음)를 명확히 분리. 인덱스는 C11 `__atomic` builtin으로 접근(디바이스별 단일 producer/단일 consumer 가정)

## Device Lifecycle

**선택한 방식: 정적 생성 + hidden/active 커스텀 property (PRD §11의 candidate B)**

이유:
- Apple 문서상 `CreateDevice`/`DestroyDevice`를 통한 동적 생성은 `PerformDeviceConfigurationChange` 핸드셰이크 등 추가 상태 관리가 필요해 Phase 1 spike 범위 대비 리스크·구현 비용이 크다고 판단
- `kAudioDevicePropertyIsHidden`은 이미 Apple이 공식 문서화한 표준 property이며, 사용자 UI(Sound 설정 등) 노출 여부를 표준 방식으로 제어할 수 있다
- `HasProperty`/`GetPropertyData`/`SetPropertyData`만으로 완결되는 가장 단순하고 예측 가능한 CoreAudio public mechanism이라고 판단해 이 방식을 우선했다

제약: 두 디바이스는 driver가 로드되어 있는 한 항상 "존재"한다(완전히 사라지지 않음). 완전한 동적 visibility보다 hidden 방식이 더 안정적이라는 PRD §11의 전제에 따라, 이 제약이 있는 채로도 **CONDITIONAL PASS 후보**로 남긴다 — 실기기에서 hidden 상태가 실제로 일반 Sound 설정 UI에 노출되지 않는지는 사용자 검증이 필요하다(§CHECKPOINT 2/3 참고).

## Control Plane

CoreAudio custom device-scope property 2개 (public `AudioObjectGetPropertyData`/`SetPropertyData` 메커니즘만 사용, 별도 소켓/파일/world-writable shared memory 없음):

| Selector | FourCharCode | 의미 |
|---|---|---|
| `kJarvisDevicePropertyActive` | `'Ract'` | UInt32 0/1. Set 시 `isActive`/`isHidden`을 함께 토글하고 해당 디바이스의 loopback buffer를 reset |
| `kJarvisDevicePropertyClearBuffers` | `'Rclr'` | write-only trigger. 값 무관하게 buffer만 reset |

## Build

| 항목 | 결과 |
|---|---|
| `swift build` (JarvisCallBridge + JarvisAudioDriverTool + JarvisLoopbackBuffer) | **PASS**, 경고 0 |
| `swift test` | **PASS** — 14/14 (Phase 0의 6건 + LoopbackBuffer 5건 + PhoneApp 1건 + Phase 0 route 2건) |
| `Scripts/build-driver.sh` | **PASS**, 경고 0, ad-hoc 서명 성공 |
| `AudioDriver/Plugin/selftest.c` (in-process, coreaudiod 없이) | **PASS** — 아래 상세 |
| `Scripts/build-app.sh` + headless 실행 | **PASS** — 3초+ 크래시 없이 유지, 정상 종료 확인 (Phase 0 regression 없음) |

Driver artifact: `bridge/AudioDriver/build/JarvisCallAudio.driver`

## Automated Tests

| Suite | 개수 | 결과 |
|---|---|---|
| `BridgeStateMachineTests` (Phase 0 4건 + Phase 1 신규 2건: route-mutation spy, **driver-activation spy**) | 6 | PASS |
| `AudioRouteManagerTests` | 2 | PASS |
| `PhoneAppDiscoveryTests` | 1 | PASS |
| `LoopbackBufferTests` (신규: roundtrip, underrun→silence, overrun→drop-oldest, reset, 2-instance 격리) | 5 | PASS |
| **합계** | **14** | **14 passed, 0 failed** |

`testWorkModeTogglingNeverActivatesAudioDriver`가 spy(`AudioDriverActivationSpy`)를 `BridgeStateMachine`에 주입한 채 Work Mode ON/OFF를 반복해 `activateCallCount`/`deactivateCallCount`가 항상 0임을 증명한다 — PRD §23 "ARMED ≠ Audio Driver Active"의 코드 레벨 보증.

## Driver Self-Test

`AudioDriver/build/selftest`를 `AudioDriver/Plugin/selftest.c`에서 빌드해 `JarvisCallAudio.driver`의 Mach-O를 `dlopen()`으로 직접 로드하고 아래를 in-process로 검증했다(coreaudiod 없이, sudo 없이, 설치 없이):

- factory 함수, `QueryInterface`, `Initialize` — PASS
- PlugIn `DeviceList`가 정확히 2개 디바이스 반환 — PASS
- 두 디바이스 각각: `DeviceUID` 정확한 문자열 일치, `IsHidden` 초기값 true, **`CanBeDefaultDevice`/`CanBeDefaultSystemDevice` 항상 0(안전 불변조건)**, output stream format 48kHz/2ch, output/input stream `Direction` 값(0/1) 정확, 존재하지 않는 property 요청 시 `kAudioHardwareUnknownPropertyError`(임의 성공 아님), `Active` property Set→Get 왕복 및 그에 따른 `IsHidden` 자동 전환 — 전부 PASS

이 결과는 **"vtable이 링크되고 두 디바이스/네 스트림 객체 모델이 property 조회에 올바르게 응답한다"**는 것만 증명한다. **"coreaudiod가 실제로 로드한다"나 "실제 loopback 오디오가 끝까지 동작한다"는 증명하지 않는다** — 이 두 가지는 각각 `install-driver.sh` 실행과 `JarvisAudioDriverTool`을 이용한 실기기 loopback 테스트가 필요하며, 이번 세션에서는 수행하지 않았다(§19 규칙에 따라 sudo/설치를 에이전트가 실행하지 않음).

## Safety

- **No ScreenCaptureKit** — 이번 Phase 코드 어디에도 import 없음
- **No shared-memory PCM** — `shm_open`/`mmap` 코드 없음. 유일한 버퍼는 driver 프로세스(coreaudiod) 내부의 `JarvisLoopbackBuffer`(디바이스당 1개, cross-process 아님)
- **No default route mutation** — 앱/드라이버/CLI 어디에도 `AudioObjectSetPropertyData`로 `kAudioHardwarePropertyDefault*Device`를 쓰는 코드가 없음. 추가로 두 디바이스는 `CanBeDefaultDevice`/`CanBeDefaultSystemDevice=false`를 항상 응답해 macOS가 애초에 이들을 기본 장치 후보로 취급하지 않도록 구조적으로 차단
- **No Phone.app routing** — Phone.app 관련 코드 없음(Phase 0의 `PhoneAppDiscovery`는 읽기 전용 존재 확인만, 변경 없음, 이번 Phase에서 수정 안 함)
- **No auto-answer** — Accessibility API 사용 코드 없음(Phase 0의 `AccessibilityStatus`도 변경 없음)
- **No Realtime** — 관련 코드/의존성 없음
- **Claude Code did not run sudo** — `Scripts/install-driver.sh`/`uninstall-driver.sh`는 작성만 하고 이번 세션에서 실행하지 않음. 이번 세션에서 실제로 실행한 명령은 `swift build`/`swift test`/`swift run JarvisAudioDriverTool status|activate|test-capture`(전부 "NOT FOUND"로 안전하게 실패)/`Scripts/build-driver.sh`/`Scripts/build-app.sh`/`open`(앱 실행·종료)/`git status`뿐이다
- **No unrelated HAL driver touched** — `install-driver.sh`/`uninstall-driver.sh` 둘 다 `/Library/Audio/Plug-Ins/HAL/JarvisCallAudio.driver` 하드코딩 단일 경로만 대상. 현재 이 Mac에는 `AITakeCallAudioDriver.driver`, `JumpAudio.driver`, `JumpAudioMic.driver`, `ParrotAudioPlugin.driver`, `TVRemoteAudio.driver`가 이미 설치되어 있으며 이번 세션에서 그중 어느 것도 조회 이상의 접근을 하지 않았다

## Manual Validation

**STATUS = WAITING FOR MANUAL DRIVER INSTALL**

### 설치 전 rollback 방법 (먼저 확인)

```sh
cd bridge
sudo ./Scripts/uninstall-driver.sh
```

`JarvisCallAudio.driver` 하나만 정확한 경로로 제거하고 `coreaudiod`를 재시작한다. 다른 드라이버는 건드리지 않는다. 설치 전에도 안전하게 실행 가능(대상이 없으면 `rm -rf`가 조용히 아무 일도 하지 않음).

### CHECKPOINT 1 이후 사용자가 수행할 절차 (요약, 본문은 채팅 메시지 참고)

1. `cd bridge && sudo ./Scripts/install-driver.sh` — 통화 중이 아닐 때, `coreaudiod` 재시작 발생
2. `swift run JarvisAudioDriverTool status` — 두 디바이스 모두 발견되는지, `hidden=true`인지, `canBeDefault=false`인지 확인
3. `swift run JarvisAudioDriverTool activate` → `test-capture` → `test-inject` → `test-isolation` → `stress` 순서로 실행
4. 각 명령의 "RESULT: PASS/FAIL"과 route unchanged 여부를 이 문서에 기록
5. `sudo ./Scripts/uninstall-driver.sh`로 정리(선택)

## Phase Result

에이전트 단계(빌드/자동테스트/self-test)에서 확보 가능한 모든 증거는 PASS다. PRD §35/§36 Phase Gate 원칙에 따라, 실제 coreaudiod 로드와 실제 loopback audio 검증 없이는 PASS/CONDITIONAL PASS/FAIL을 확정하지 않는다.

**CB v2 Phase 1 = WAITING FOR MANUAL DRIVER INSTALL**
