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

## CHECKPOINT 2 — 1차 시도 결과 및 수정 (2026-08-15, 이어지는 세션)

### 사용자가 실제로 설치/검증한 결과

- `/Library/Audio/Plug-Ins/HAL/JarvisCallAudio.driver` 정상 설치, `coreaudiod` 정상 재시작
- 다른 HAL driver(AITakeCallAudioDriver, JumpAudio, JumpAudioMic, ParrotAudioPlugin, TVRemoteAudio) 영향 없음 확인
- Default Input/Output/System Output 기존 값 그대로 유지 확인
- `system_profiler SPAudioDataType`에는 두 디바이스가 보이지 않음 — hidden 디자인 의도와 일치, 정상
- `swift run JarvisAudioDriverTool status` 실행 결과 **`Ract`(Active) 커스텀 property 조회가 `kAudioHardwareUnknownPropertyError`('who?')로 실패** — CHECKPOINT 2 BLOCKED

### Root Cause

`AudioServerPlugIn.h`가 명시적으로 문서화하는 제약을 놓쳤다:

> `kAudioServerPlugInCustomPropertyDataTypeNone` / `CFString` / `CFPropertyList` ... "These are the only types supported for custom properties."

`kJarvisDevicePropertyActive`('Ract')/`kJarvisDevicePropertyClearBuffers`('Rclr')를 원시 `UInt32`로 marshaling하도록 구현했는데, **raw UInt32는 custom property에 대해 host가 지원하는 marshaling 타입이 아니다.** 이 때문에:

- **in-process self-test** (같은 프로세스에서 함수 포인터를 직접 호출, 실제 marshaling/IPC 경로를 타지 않음) — 문제없이 PASS
- **실제 coreaudiod를 통한 cross-process 호출** — host의 property marshaling 레이어가 커스텀 property의 타입을 검증하면서 UInt32를 거부, `GetPropertyData`가 우리 드라이버 코드에 도달하기도 전에 `kAudioHardwareUnknownPropertyError`로 실패

이것이 정확히 CHECKPOINT 1의 self-test가 전부 PASS했음에도 실제 설치된 드라이버에서 실패한 이유다 — self-test는 marshaling 경로 자체를 검증하지 못하는 구조적 한계가 있었다.

추가로, 개선된 진단 코드(§아래 Changed 참고)로 재확인하는 과정에서 **두 번째, 관련은 없지만 유사한 증상의 문제**도 발견했다: `kAudioDevicePropertyDeviceCanBeDefaultDevice`를 `kAudioObjectPropertyScopeGlobal`로 조회하면 마찬가지로 실패한다. 이는 원래 CHECKPOINT 1의 진단 코드가 하나의 `do/catch` 블록에서 여러 property를 순차 조회하다가 `Ract` 실패 시점에 예외가 발생해 이후 코드가 아예 실행되지 않아 가려져 있던 기존 문제였다. Apple 관례상 `CanBeDefaultDevice`는 Global이 아니라 Input/Output scope별로 조회해야 하는 property이며, Global scope 조회 자체를 host가 우리 driver에 전달하기 전에 거부하는 것으로 보인다 — Input/Output scope로 조회하도록 client 코드를 수정하니 (여전히 구버전이 설치된 상태에서) 즉시 해결되는 것을 직접 확인했다(driver 쪽 코드는 애초에 scope를 구분하지 않고 항상 0을 반환하므로 변경 불필요).

### Changed

- `AudioDriver/Plugin/PlugInTypes.h`, `PlugInInterface.c`:
  - `kAudioObjectPropertyCustomPropertyInfoList`('cust')를 두 Device 객체에 구현 — `Ract`/`Rclr`를 `kAudioServerPlugInCustomPropertyDataTypeCFPropertyList`로 선언
  - `kJarvisDevicePropertyActive`/`kJarvisDevicePropertyClearBuffers`의 `GetPropertyDataSize`/`GetPropertyData`/`SetPropertyData`를 `UInt32` → `CFTypeRef`(`CFBooleanRef`, `kCFBooleanTrue`/`kCFBooleanFalse`) marshaling으로 변경
  - 두 property 모두 `kAudioObjectPropertyScopeGlobal` 이외의 scope 요청 시 `kAudioHardwareUnknownPropertyError`를 명확히 반환하도록 scope 검증 추가 (`HasProperty`/`IsPropertySettable`/`GetPropertyDataSize`/`GetPropertyData`/`SetPropertyData` 전부)
  - `SetPropertyData`가 `CFBooleanRef`뿐 아니라 `CFNumberRef`도 관대하게 허용하는 `CFTypeRefIsTruthy()` 헬퍼 추가(방어적)
- `AudioDriver/Plugin/selftest.c`: `HasProperty('Ract')`, `GetPropertyDataSize('Ract')`, CFBoolean 기반 Get/Set 왕복, scope mismatch 오류, `kAudioObjectPropertyCustomPropertyInfoList` 조회, **Capture/Inject 각각 독립된 active state**(한쪽만 activate했을 때 반대쪽이 영향받지 않음)까지 검증하는 케이스 추가
- `Sources/JarvisAudioDriverTool/CoreAudioHelpers.swift`: `getBoolProperty`/`setBoolProperty`/`triggerProperty`(CFBoolean marshaling) 추가, 더 이상 쓰이지 않는 `setUInt32` 제거
- `Sources/JarvisAudioDriverTool/Commands.swift`: `printDeviceStatus`가 found/deviceID/UID를 항상 먼저 출력하고, 이후 각 property를 **개별 `do/catch`**로 분리해 "하나가 실패해도 나머지는 계속 진단"하도록 개선(이번에 `CanBeDefaultDevice` 문제를 실제로 찾아낸 방식). `CanBeDefaultDevice`를 Output/Input scope로 각각 조회하도록 수정. `activate`/`deactivate`/`clear`/loopback 테스트들도 새 CFBoolean 헬퍼 사용하도록 갱신
- `Sources/JarvisCallBridge/System/AudioDriverStatus.swift`: 앱 UI의 "Call Audio Driver" 상태 표시도 동일하게 CFBoolean marshaling(`getCustomBool`)으로 수정

### Build

- swift build: **PASS**, warnings: **0**
- driver build (`Scripts/build-driver.sh`): **PASS**, warnings: **0**

### Tests

- **14 passed**, 0 failed (Phase 0/1 기존 스위트 전체 재확인, 신규 추가 없음 — 이번 수정은 driver/CLI 레이어라 Swift 유닛테스트 대상 밖)

### Custom Property Self-Test

- HasProperty Ract: **PASS**
- GetPropertyDataSize Ract: **PASS**
- GetPropertyData Ract: **PASS**
- SetPropertyData Ract: **PASS**
- Capture independent state: **PASS**
- Inject independent state: **PASS**
- (추가) Scope mismatch(Input/Output로 Ract 조회) → `kAudioHardwareUnknownPropertyError`: **PASS**
- (추가) `kAudioObjectPropertyCustomPropertyInfoList` 조회 및 내용 검증: **PASS**

전부 in-process self-test 기준이며, **실제 coreaudiod를 통한 marshaling까지 검증하려면 재설치가 필요하다** — 정확히 이번 버그가 self-test만으로는 잡히지 않았던 이유이므로, 재설치 전에는 "고쳤다"고 선언하지 않는다.

### Safety

- sudo not executed
- installed driver not modified (현재 `/Library/Audio/Plug-Ins/HAL/JarvisCallAudio.driver`는 여전히 버그가 있는 구버전 그대로임 — 이번 세션은 로컬 소스/빌드만 수정)
- default route not changed
- hidden 정책을 우회하거나 없애지 않음 — `IsHidden` 관련 코드는 이번 수정에서 건드리지 않음

### Next

**MANUAL DRIVER REINSTALL REQUIRED**

```sh
cd bridge
sudo ./Scripts/uninstall-driver.sh   # 기존 구버전 제거 (선택이지만 권장 — 깨끗한 재설치)
sudo ./Scripts/install-driver.sh     # 수정된 새 빌드 설치
swift run JarvisAudioDriverTool status
```

## Phase Result

에이전트 단계(빌드/자동테스트/self-test)에서 확보 가능한 모든 증거는 PASS다. PRD §35/§36 Phase Gate 원칙에 따라, 실제 coreaudiod 로드와 실제 loopback audio 검증 없이는 PASS/CONDITIONAL PASS/FAIL을 확정하지 않는다.

**CB v2 Phase 1 = WAITING FOR MANUAL DRIVER REINSTALL (fix applied, not yet verified on real hardware)**
