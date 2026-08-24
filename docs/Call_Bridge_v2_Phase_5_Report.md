# CB v2 Phase 5 Report — Jarvis Agent Integration

작성일: 2026-08-24
최종 판정:

- **Phase 5 CHECKPOINT 1**: **FINAL PASS** — Jarvis 인증 + ephemeral Realtime 키
- **Phase 5 CHECKPOINT 2**: **IN PROGRESS** — 수신 보고 + 로컬 인코딩 + R2
- **Phase 5**: **IN PROGRESS** — 자동 발신 / 앱 푸시 / 메일 / 통화 중 Tool은 여기 없다

스펙(CP1): `docs/superpowers/specs/2026-08-24-phase5-cp1-jarvis-ephemeral-realtime-design.md`  
계획(CP1): `docs/superpowers/plans/2026-08-24-phase5-cp1-jarvis-ephemeral-realtime.md`  
스펙(CP2): `docs/superpowers/specs/2026-08-24-phase5-cp2-incoming-call-report-design.md`  
계획(CP2): `docs/superpowers/plans/2026-08-24-phase5-cp2-incoming-call-report.md`

드라이버는 이 체크포인트에서 수정·재설치하지 않는다. `bridge/.env`와 `api/.dev.vars`는 gitignore. 키 미커밋.

## 자동화

- 2026-08-24 CP1 구현 직후: `cd api && npm test` **105 passed, 0 failed**. `cd bridge && swift test` **379 passed, 0 failed**.
- 2026-08-24 CP2 구현 직후 (실기기 전):
  - `cd api && npm test` **113 passed, 0 failed**
  - `cd bridge && swift test` **388 passed, 0 failed**
  - `cd admin && npm test` **9 passed, 0 failed**
  - `cd web && npm test` **9 passed, 0 failed**


## CHECKPOINT 1 — 실기기 FINAL PASS (2026-08-24 18:53)

사전 mint (Mac Studio 로컬):

```text
POST https://jarvis-api.twms.ai/api/realtime/client-secret
http=200  has_ek True  expiresAt_int True  model gpt-realtime-2.1-mini
keys ['expiresAt', 'model', 'value']
```

UI (사용자 스크린샷):

- Ringing: Realtime **Armed**, Auto Answer 카운트다운
- Active: Realtime **Connected**, PCM Running, RX Activity **Active**, TX frames 증가, Auto Answer Last attempt **Success**

증거:

- 로그: `~/Documents/jarvis-call-bridge-log-20260824-185325.txt`
- RX: `~/Documents/jarvis-call-bridge-rx-20260824-185302.wav` — 19.795 s, 24 kHz mono PCM16, peak 12450, nonzero 90.76%
- TX: `~/Documents/jarvis-call-bridge-tx-20260824-185302.wav` — 2.450 s, peak 15550, nonzero 99.10%

로그 요지:

- `18:52:51.100` Ringing, Auto Answer scheduled 3s
- `18:52:56.742` Auto Answer press **success** → answering
- `18:52:59.893` Active (grace 안) + PCM `rxSource=continuity-tap` + AUHAL start
- Active 구간 `activity=active` 여러 번, `txUnderrunCount=0`
- `18:53:21.588` Idle, route restore verification pass
- `ek_`, `sk-`, `Bearer`, `JARVIS_API_TOKEN` 매치 **0**

WAV는 adapter `connect()` 성공 뒤에만 열린다. TX 2.45 s는 한 턴 짧은 AI 답과 맞다. Inject UI TX 프레임은 침묵/워터마크까지 세므로 WAV보다 길다.

`bridge/.env`에 `OPENAI_API_KEY` 줄이 남아 있어도 connect는 쓰지 않는다. adapter Bearer는 mint `value`만 넣는다. 키를 지워도 같은 경로다.

**Phase 5 CHECKPOINT 1 = FINAL PASS.** 이 체크포인트는 다시 열지 않는다.

## CHECKPOINT 2 — 구현 완료, 실기기 게이트 대기

코드:

- Worker `POST/GET /api/calls`, `PUT/GET /api/calls/{id}/audio`, `POST /api/calls/{id}/complete`
- R2 바인딩 `CALLS_BUCKET` / 버킷 `jarvis` / 키 `jarvis-call/{id}/merged.m4a`. 듣기는 인증된 `GET /api/calls/{id}/audio`. 공개 `r2.twms.ai` URL은 API에 넣지 않음.
- Bridge: Connected에서 create, Idle에서 RX+TX 믹스 → AAC m4a → upload/complete
- 발신자: 연락처 이름+번호, 없으면 `unknown`+번호. `[CALL]` 로그에 PII 없음
- Playground: 5초 폴링 배너 + Notification. 채팅 세션에 섞지 않음
- Admin: `통화` 메뉴

**Phase 5 CHECKPOINT 2는 아직 PASS가 아니다.** 실기기에서 R2 배포 후 착신 1회를 Admin/Playground에서 확인하기 전 FINAL PASS를 쓰지 않는다.

**Phase 5 COMPLETE 아님.** 자동 발신 / 앱 푸시 / 메일 / 통화 중 Tool은 자동 시작하지 않는다.
