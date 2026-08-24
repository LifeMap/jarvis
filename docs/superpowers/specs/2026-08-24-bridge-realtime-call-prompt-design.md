# Bridge Realtime 통화 프롬프트

날짜: 2026-08-24  
상태: 설계 승인 — 구현  
브랜치: `phase5`  
근거: Realtime 말투가 통화마다 존댓말/반말로 흔들림. 앱에서 고정할 수 있어야 함.

이 문서는 Bridge 로컬 말투·추가 프롬프트만 정의한다. Admin 동기화, 통화 중 재적용, 발신, Keychain은 여기 없다.

---

## 1. 한 줄 목표

Bridge 앱에서 존댓말/반말과 추가 프롬프트를 저장하고, 다음 착신 Realtime 연결의 `session.update.instructions`에만 적용한다.

---

## 2. 잠근 결정

| 항목 | 결정 |
|---|---|
| UI | 말투 선택 + 추가 프롬프트. Realtime 토글 아래 |
| 저장 | 이 Mac UserDefaults만. Admin과 별개 |
| 적용 시점 | 다음 착신 Realtime `connect` 때. 통화 중 `session.update` 추가 없음 |
| 조합 | 고정 기본문 + 말투 한 줄 + (있으면) 추가 프롬프트 |
| 기본 말투 | 존댓말 (`polite`) |
| 추가 프롬프트 비움 | 기본문+말투만. 빈 줄은 생략 |
| 추가 프롬프트 최대 | 저장 시 앞뒤 공백 제거, 2000자에서 자름 |
| 잘못된 저장값 | 말투는 `polite`로 복귀 |
| session.update | `instructions`만 교체. VAD/PCM/전사/`turn_detection` 위치 불변 |
| 로그 | `[CALL] realtime instructions style=polite\|casual extra=set\|empty`. 본문·PII 없음 |
| 드라이버/PCM/mute/barge-in | 수정 없음 |
| Admin `assistant_speech_style` | 읽지 않음, 쓰지 않음 |

---

## 3. 아키텍처

```text
앱 UI (말투 + 추가 프롬프트)
  → UserDefaults
  → 다음 Realtime connect
  → compose(base + style + extra)
  → OpenAIRealtimeVoiceAdapter(instructions:)
  → session.update.instructions
```

`OpenAIRealtimeVoiceAdapter`는 이미 `instructions`를 받는다. 기본값은 고정 기본문이다. 프로덕션 `makeAdapter`가 연결 순간에 조합 결과를 넣는다.

---

## 4. 조합 규칙

고정 기본문 (기존 `OpenAIRealtimeVoiceAdapter.defaultInstructions`와 동일):

```text
당신은 전화로 통화 중인 한국어 비서입니다.
상대가 쓰는 언어로 맞춰, 짧게 자연스럽게 대답하세요.
```

말투 한 줄:

- `polite`: `항상 존댓말로만 말하세요. 반말을 쓰지 마세요.`
- `casual`: `항상 반말로만 말하세요. 존댓말을 쓰지 마세요.`

추가 프롬프트가 있으면 빈 줄 뒤에 그대로 붙인다. 없으면 붙이지 않는다.

---

## 5. UI

Realtime 토글 아래:

- 말투: `존댓말` / `반말`
- 추가 프롬프트: 여러 줄. placeholder는 `다음 착신부터 적용되는 추가 지시`
- 안내: `다음 착신부터 적용`

통화 중 수정은 저장만 하고, 현재 세션에는 보내지 않는다.

---

## 6. 저장

UserDefaults 키:

- `jarvis.realtime.speechStyle` — `"polite"` \| `"casual"`
- `jarvis.realtime.extraInstructions` — 문자열

앱 재실행 후에도 유지된다.

---

## 7. 테스트

- 존댓말 조합에 존댓말 줄이 있고 반말 줄이 없다
- 반말 조합은 그 반대
- 추가문 없음 → 기본문+말투만
- 추가문 있음 → 말투 다음에 추가문
- 공백-only 추가문은 없는 것과 같다
- 2000자 초과는 잘린다
- 알 수 없는 저장 말투는 `polite`
- adapter `connect`는 주입한 `instructions`를 `session.update`에 넣는다
- 기본 adapter 테스트의 VAD/PCM/전사 단언은 그대로
- 로그 문자열에 추가 프롬프트 본문이 없다

실 OpenAI 호출은 단위 테스트에 없다.

---

## 8. 완료 판정

```text
PASS
  - 해당 bridge 테스트 통과
  - 앱에서 말투/추가문을 고치면 재실행 후에도 남음
  - 다음 착신 session.update에 조합문이 들어감 (단위 테스트로 증명)
  - VAD/PCM/mute/barge-in 변경 없음

실기기 말투 체감은 사용자 확인. 이 문서 PASS만으로 Phase 5 COMPLETE 아님
```

---

## 9. 명시적 비범위

- Admin 말투/커스텀 지시 동기화
- 통화 중 instructions 재전송
- 발신, 앱 푸시, 메일, Keychain
- 드라이버 수정
- 프롬프트 본문을 로그에 남기는 일
