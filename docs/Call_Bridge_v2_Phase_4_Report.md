# CB v2 Phase 4 Report — Realtime Voice

작성일: 2026-08-21
최종 판정 (에이전트 단계, 최신 상태 — 아래는 매 체크포인트마다 갱신되며 과거 기록은 하단에 그대로 보존):

- **Phase 4 CHECKPOINT 1**: **FINAL PASS** — TX 링 + 변환 + adapter/세션 순서. 앱에 OpenAI 없음. 실기기: Active+PCM에서 1 kHz 1초 연속 청취 (2026-08-22)
- **Phase 4 CHECKPOINT 2**: **FINAL PASS** — OpenAI Realtime 한 턴 speech-to-speech. 앱 안 WebSocket. RX는 Continuity 프로세스 탭. Jarvis Agent 없음 (2026-08-22)
- **Phase 4**: **IN PROGRESS** — VAD / barge-in / 여러 턴은 CHECKPOINT 3. 자동 진행하지 않음

스펙(CP1): `docs/superpowers/specs/2026-08-21-phase4-cp1-realtime-voice-design.md`  
스펙(CP2): `docs/superpowers/specs/2026-08-22-phase4-cp2-openai-realtime-design.md`  
계획(CP2): `docs/superpowers/plans/2026-08-22-phase4-cp2-openai-realtime.md`

## 자동화

`cd bridge && swift test`

- 2026-08-22 CP2 구현 직후: **366 passed**
- 2026-08-22 Continuity 탭 RX 추가 후: **368 passed, 0 failed**

드라이버는 이 체크포인트에서 수정·재설치하지 않았다. `bridge/.env`는 gitignore. 키 미커밋.

---

## 실기기 1 kHz (CHECKPOINT 1, 2026-08-22)

첫 빌드는 링 스트리밍 때문에 1초 동안 짧은 삐가 반복됐다. 링을 1초(48000 프레임)로 키우고 사인을 한 번에 쓴 뒤 재청취: **연속 1 kHz PASS**. CHECKPOINT 2로 자동 진행하지 않는다.

---

## CHECKPOINT 2 — 구현 범위 (앱만)

잠긴 결정(`2026-08-22-phase4-cp2-openai-realtime-design.md`)대로 구현했다.

- Provider: OpenAI Realtime, 앱 안 `URLSession` WebSocket
- 모델: 코드에 박지 않음. 기본 `gpt-realtime-2.1-mini`. `.env` `OPENAI_REALTIME_MODEL` 선택
- 인증: `bridge/.env`의 `OPENAI_API_KEY`. Keychain / Jarvis ephemeral 없음
- 연결: Realtime 토글 ON **그리고** Active + PCM Running. Ringing에서 열지 않음
- 앱 재시작 시 토글 OFF
- 실패 시 route/PCM 롤백 없음
- 디버그 WAV: `~/Documents/jarvis-call-bridge-rx-*.wav`, `tx-*.wav` (24 kHz mono PCM16). Phase 7 제품 녹음 아님
- TX 링 용량 48000. Realtime 워터마크 ≈ 200 ms (9600)
- barge-in / VAD / Agent / 070 / 하드웨어 sink 없음

핵심 파일: `bridge/Sources/JarvisCallBridge/Realtime/`, `SystemCallAudioPCMController.swift`, `SystemCallAudioProcessMuteController.swift`, `CallAudioSessionController.swift`.

---

## CHECKPOINT 2 — 실기기 실패 (WriteMix 무음)

첫 실통화들(로그 `…-233020`, `…-234301` 등)은 Realtime이 붙어도 RX/TX WAV가 무음이었다.

Active 구간 진단:

| 지점 | 관측 |
|---|---|
| shm `/jarvis-callbridge-capture-rx` | `writeIndex=256` 고정 → Rrxc 폴백 |
| `captureWriteMixOps` | 계속 증가 |
| `captureWriteMixNonZero` | ringing에서만 증가 후 Active에서 고정 |
| `captureWriteMixPeakLinear` | Active에서 0 (마지막 WriteMix 피크) |
| `rrxcPeakLinear` | 0 |
| RX/TX WAV | 전부 0 / TX 0프레임 |

즉 OpenAI·변환·Rrxc 디코드가 아니라, **Active일 때 Phone.app이 Capture WriteMix에 통화 음성을 쓰지 않음**이 원인이었다. ringing의 벨/연결음만 nonZero로 쌓였다. Phase 3에서 본 Capture OUTPUT 에너지(`nonZero` 수천, `peak>0`)와 다른 상태다.

드라이버 재설치로는 이 무음이 해결되지 않는다. WriteMix 샘플 자체가 0이었다.

---

## CHECKPOINT 2 — RX 경로 개정 (앱만)

Continuity 원격 음성은 `com.apple.avconferenced`가 스피커로 쓴다. 그 프로세스는 이미 누수 방지용으로 `CATapMuted` 탭을 걸고 있었다. 탭 PCM은 버리고 있었다.

개정: mute aggregate를 PCM start 때 input-only AUHAL로 열고, `AudioUnitRender` 결과를 RX 소비 링에 넣는다. 뮤트 동작은 유지. Capture WriteMix / Rrxc는 탭 AUHAL이 실패할 때만 폴백.

- `rxTapDeviceID`를 mute 컨트롤러가 노출
- 세션이 `pcm.start(reason:rxTapDeviceID:)`로 전달
- C 콜백 `JarvisPCMProcessTapAUInputCallback` (Capture extra-client 콜백과 분리 — 그쪽 Render는 무음)

드라이버 변경 없음. 하드웨어 sink 없음.

---

## CHECKPOINT 2 — 실기기 FINAL PASS (2026-08-22 23:57)

증거:

- 로그: `~/Documents/jarvis-call-bridge-log-20260822-235804.txt`
- RX: `~/Documents/jarvis-call-bridge-rx-20260822-235749.wav` — 13.704 s, 24 kHz mono PCM16, peak 10175, nonzero 83.63%
- TX: `~/Documents/jarvis-call-bridge-tx-20260822-235749.wav` — 8.100 s, peak 17393, nonzero 99.26%

로그 요지:

- `continuity-tap native format 48000Hz Float32 2ch interleaved deviceID=333`
- `continuity-tap auhal started`
- `[CALL-PCM-METRICS] rxSource=continuity-tap` — `rawPeakLinear`가 0이 아님 (`0.095`까지), `activity=active` 구간 존재
- `readableNonZeroBufferCount`가 콜백과 같이 증가
- `txUnderrunCount=0` 전 구간
- 종료 후 PCM stop → mute stop → route restore (기존 순서)

판정: 상대 말 → Continuity 탭 → OpenAI → Inject → 상대 폰에서 AI 답. 스펙 §6 항목 5–6 **PASS**.

통화 중 상대 폰에서 조금씩 끊겨 들린 것은 디버그 WAV에는 없다. WAV는 OpenAI로 주고받은 PCM을 순서대로 붙인 것이고, Inject 언더런은 0이다. 파일에 없는 끊김은 Phone/Continuity/셀룰러 전달 쪽으로 둔다. CP2 실패로 보지 않는다.

토글 OFF가 연결만 끊는지, 앱 재시작 시 토글이 꺼지는지, Realtime 실패가 route를 롤백하지 않는지는 단위/세션 테스트로 고정되어 있다. 한 턴 실기기 게이트가 이 체크포인트의 막힌 항목이었다.

**Phase 4 CHECKPOINT 2 = FINAL PASS.** 이 체크포인트는 다시 열지 않는다. Phase 5와 barge-in은 여전히 여기 없다.

---

## Phase 4 잔여 (CHECKPOINT 3, 미착수)

PRD Phase 4 완료 기준 중 CP2에 넣지 않은 것:

- 여러 턴 대화
- VAD
- barge-in / local TX clear / response cancel

스펙 없음. 에이전트는 CHECKPOINT 2 PASS 뒤에 다음 체크포인트를 자동으로 시작하지 않는다.
