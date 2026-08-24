# Phase 5 — 부재중 콜백 발신

날짜: 2026-08-24  
상태: 설계 승인 — 스펙  
브랜치: `phase5`  
근거: 착신 Auto Answer가 받을 기회가 있었는데 못 받은 번호를, Mac Phone.app Continuity로 다시 건다.  
선행: Phase 5 CHECKPOINT 1 FINAL PASS, CHECKPOINT 2 수신 보고(구현됨)

이 문서는 **부재중 콜백 발신**만 정의한다.

Call Bridge v1.0에서 하지 않음: Memory, 통화 중 Tool call, Approval, Agent Scheduler, 앱 푸시, 메일 알림, A→B 착신전환, 070/SIP.

---

## 1. 한 줄 목표

Auto Answer가 켜져 있는데 받을 수 있었던 착신을 놓치면, 스케줄러가 그 번호를 오래된 것부터 한 통씩 다시 건다. 상대가 받으면 발신 인사로 받고, 안 받으면 끊고 Jarvis `통화`에 이력을 남긴다.

---

## 2. 잠근 결정

| 항목 | 결정 |
|---|---|
| 제품 | 부재중 콜백만. 임의 번호 걸기·주소록 선택 걸기 없음 |
| 트리거 | Work Mode 켜짐 + Auto Answer 켜짐 + Ringing 후 Active 없이 Idle + **Ringing 지속 ≥ Auto Answer 지연** |
| 짧은 벨 | Ringing < Auto Answer 지연이면 큐에 넣지 않음 (카운트다운 전 상대가 끊음) |
| 넣지 않음 | 직접 수신, Auto Answer 성공, Auto Answer 꺼짐, Work Mode 꺼짐 |
| 거절 검출 | 이 체크포인트에서 거절 버튼을 따로 보지 않음. 지연 이후 거절도 부재중으로 넣을 수 있음 |
| 큐 | 이 Mac UserDefaults. 번호 + 최초 Ringing 시각. 번호 `unknown`은 큐에 안 넣음 |
| 중복 | 같은 번호가 큐에 있으면 추가하지 않음 |
| 스케줄 | 주기(분) 화면에서 정함. 기본 **5**. 한 틱에 **가장 오래된 1통** |
| 시도 | 번호당 **1회**. 건 뒤 큐에서 제거. 재시도 없음 |
| 발신 경로 | `tel:` → Mac Phone.app → Continuity 셀룰러. 키패드 AX·단축어 없음 |
| 미응답 제한 | 화면에서 초 단위. 기본 **45**. 그 안에 Active가 아니면 종료를 눌러 끊음 |
| 연결됨 | 저장한 **발신 인사**를 수신과 같이 한 번만. 녹음·`/api/calls` 보고는 수신과 동일, `direction=outgoing` |
| 연결 안 됨 | 오디오 없음. `/api/calls`에 발신 이력. 요약 고정 문구. LLM 요약 없음 |
| 번호 없음 | 큐에 안 넣음. 같은 API에 이력만. 요약 `번호 없음` |
| 보기 | Admin `통화`, Playground 기존 폴링. 채팅 세션에 섞지 않음 |
| 스케줄 정지 | Ringing / Answering / Active 이거나 콜백 발신이 진행 중이면 다음 틱은 걸지 않음 |
| 로그 | `[CALL-CALLBACK] result=enqueued\|skipped\|dial\|connected\|no_answer\|no_number\|hangup`. `phone=found\|missing`. 번호·이름 없음 |
| 드라이버 | 이 체크포인트에서 수정·재설치 없음 |
| Phase 5 COMPLETE | 이 체크포인트만으로 선언하지 않음 |

---

## 3. 부재중 정의

Ringing 시작 시각은 `CallLifecycleTracker`가 `.ringing`으로 바꾼 시점이다. Idle로 떨어질 때 `now - ringingStartedAt`을 Auto Answer `delaySeconds`와 비교한다.

```text
부재중 (큐 후보)
  Work Mode on
  AND Auto Answer on
  AND 이번 세션이 Active / Answering에 한 번도 안 감
  AND ringingDuration >= delaySeconds
  AND phoneNumber != "unknown"  → 큐에 넣음
  AND phoneNumber == "unknown"  → 큐 없이 이력만 (번호 없음)

아님
  ringingDuration < delaySeconds
  OR Auto Answer off
  OR Work Mode off
  OR Active를 한 번이라도 봄 (자동/수동 수신)
```

---

## 4. 아키텍처

```text
착신 Ringing
  → 번호·ringingStartedAt 기록
  → Auto Answer 지연 후 응답 시도 (기존)

Ringing → Idle, Active 없음
  → 부재중이면 큐 append (번호 중복이면 no-op)
  → 번호 없으면 POST /api/calls + complete (outgoing, failed, summary=번호 없음)

스케줄러 틱 (기본 5분, 설정 가능)
  → Auto Answer off 또는 통화 중이면 return
  → 큐가 비면 return
  → 가장 오래된 1건 pop
  → open tel:<e164-or-local>
  → 제한 시간(기본 45초) 안에 Active?
       yes → 발신 인사 Realtime 연결 (기존 PCM/보고, direction=outgoing)
       no  → AX 종료 1회
            → POST /api/calls + complete
               direction=outgoing, status=failed
               summary=콜백 연결 안 됨
               transcript=[], hasAudio=false
```

`tel:`이 열리지 않아도 그 번호는 이미 pop 됨. 이력은 `콜백 연결 안 됨`과 같다. 재시도하지 않음.

---

## 5. API

기존 `POST /api/calls` · `POST /api/calls/{id}/complete`를 쓴다. `direction`은 이미 `incoming | outgoing`이다.

연결 안 됨 / 번호 없음:

- `POST` `{ direction: "outgoing", caller, startedAt }`
- `complete` `{ endedAt, transcript: [], uploadFailed: true, summary }`
- Worker는 전사가 비어 있으면 LLM 요약을 만들지 않음. 클라이언트가 준 `summary`만 저장
- 허용 `summary`: `콜백 연결 안 됨` | `번호 없음`
- `status=failed`, `hasAudio=false`

연결됨:

- 수신 CP2와 동일. `direction=outgoing`. 폴더 키는 기존 `S_<서울시각>_<번호>`

Admin / Playground는 `direction`과 `summary`를 그대로 보여 주면 된다. 배너 조건은 기존처럼 새 레코드. 채팅에 넣지 않음.

---

## 6. UI (Call Bridge)

Auto Answer 아래에만 둔다.

- 콜백 주기 (분), 기본 5, 최소 1, 최대 60
- 미응답 후 끊기 (초), 기본 45, 최소 15, 최대 120
- 큐 개수 (읽기 전용)

발신 인사 칸은 이미 있다. 콜백이 연결되면 그 문장을 쓴다. 비어 있으면 수신과 같이 기본 인사 문장을 쓰지 않고, 발신용으로 저장한 값이 있을 때만 그대로 말한다. 비어 있으면 Realtime 기본문+말투만 (수신 기본 인사를 발신에 넣지 않음).

---

## 7. 발신·끊기

- 걸기: `tel:` URL. 번호는 큐에 저장한 문자열. `[CALL]` / 콜백 로그에 번호를 쓰지 않음
- 연결 판정: 기존 `CallLifecycleTracker`가 `.active`
- 끊기: 기존 착신과 같은 Notification Center / Phone 배너의 **종료** 후보. high 1개일 때만 1회. 실패해도 큐에는 이미 없음. 이력은 남김
- Realtime은 Active 뒤에만 PCM/펌프. 벨만 울리는 동안은 수신 `prepare`와 같이 핸드셰이크만 가능

---

## 8. 테스트

단위 테스트 (실 Phone.app / 실 발신 없음):

- Ringing 2초, AA 지연 3초, Idle → 큐 비어 있음
- Ringing 5초, AA 지연 3초, Idle, 번호 있음 → 큐 1
- 같은 번호 두 번 부재중 → 큐 1
- 번호 unknown → 큐 0, 보고 `번호 없음` 1회
- AA off / Work Mode off → 큐 0
- Active를 본 세션 → 큐 0
- 스케줄 틱: 오래된 1건만 pop, `tel:` 요청 1회
- 틱 중 Ringing/Active면 걸지 않음
- 45초 내 Active 없음 → hangup 1회 + complete `콜백 연결 안 됨`
- complete 빈 전사 + 고정 summary → LLM 호출 없음

실기기 (구현 후):

1. AA 3초, 1초 만에 상대가 끊음 → 콜백 없음
2. AA 3초, 5초 울린 뒤 못 받음 → 5분(또는 테스트용 1분) 뒤 그 번호로 발신
3. 안 받으면 제한 시간에 끊김, Admin에 `콜백 연결 안 됨`
4. 받으면 발신 인사, 녹음 `S_…` 로 보임
5. 로그에 번호/이름/`tel:` 전체 없음

---

## 9. 완료 판정

```text
PASS
  - 위 단위 테스트 통과
  - 실기기 2·3 또는 2·4
  - 키 미커밋, 드라이버 미변경

이 체크포인트만으로 Phase 5 COMPLETE 아님
```

---

## 10. 명시적 비범위

- Memory / Tool / Approval / Agent Scheduler / 앱 푸시 / 메일
- 통신사 착신전환, A 앱에서 B로 토스
- 임의 번호·연락처 선택 발신
- 콜백 재시도, 동시 2통 발신
- 거절 버튼 전용 검출
- 키패드 AX, 단축어, 070/SIP
- 드라이버 수정
