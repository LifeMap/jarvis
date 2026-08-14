# Cloudflare Personal Assistant MVP PRD

> 구현 메모 (2026-08-14): 리팩터링 Phase 4에서 Agents SDK 공식 MCP Client 기반 Generic MCP Consumer가 추가되었다. `mcp_server_configuration`은 Secret을 제외한 서버 metadata, enabled 상태, service/provider ID 및 capability mapping을 영속화한다. Secret은 `credentialReference`로만 참조한다. 논리 Tool 이름은 유지하고 mapping layer가 발견된 MCP Tool 이름으로 변환하며, 연결·credential·필수 capability 검증 실패 시 기존 active Provider를 보존한다. 미매핑 동적 Tool adapter는 보수적으로 Approval Required 정책을 사용하고 서비스 정책에 명시적으로 편입되기 전에는 LLM에 자동 노출하지 않는다. Cloudflare 공식 Documentation MCP를 통해 `brave-api → cloudflare-docs-mcp → brave-api` 무배포 전환과 실제 Tool 호출을 검증했다. Documentation MCP는 Cloudflare 문서 검색 전용이다.

> 구현 메모 (2026-08-14): 리팩터링 Phase 5에서 기존 Model Configuration, Tool Provider Configuration, MCP Registry를 orchestration하는 `RuntimeConfigurationManager`를 추가했다. 전체 Secret-free snapshot, section 조회, validation-first 복합 변경, Model/Tool reset, MCP Registry를 보존하는 전체 reset과 변경 history를 지원한다. `runtime_configuration_history`에는 target과 이전/신규 selection 및 source만 저장하며 token, API key, credential, authorization 값은 제거한다. 명확한 action verb가 있는 사용자 명령만 mutation으로 처리하며, 복합 변경은 전 항목 validation 성공 후 적용되고 실패하면 기존 설정을 유지한다.

## 1. 문서 개요

- 문서명: Cloudflare Personal Assistant MVP PRD
- 버전: v1.0
- 목적: 개인용 AI 비서 시스템의 1차 MVP 개발 기준 정의
- 개발 도구: Codex
- 배포 환경: Cloudflare
- 대상 사용자: 단일 사용자 본인
- 작성 기준일: 2026-08-12

---

## 2. 제품 목표

Cloudflare Agents 기반의 개인용 AI 비서를 구축한다.

1차 MVP에서는 웹 기반 Playground를 통해 Agent 기능을 검증하고, 관리자 웹에서 Memory, Tool, Scheduler, 실행 기록 등을 관리할 수 있도록 한다.

iPhone 및 Apple Watch 앱은 1차 MVP 이후 단계에서 개발하며, 모바일/워치 앱은 복잡한 비즈니스 로직 없이 음성 명령 입력과 결과 출력에 집중하는 Thin Client로 설계한다.

---

## 3. 핵심 원칙

- Agent 로직은 Cloudflare에 집중한다.
- 클라이언트는 가능한 한 단순하게 유지한다.
- 외부 DB는 사용하지 않는다.
- Vector DB는 1차 MVP에서 사용하지 않는다.
- Agent 상태 및 데이터는 Durable Objects + SQLite를 기본 저장소로 사용한다.
- 조회성 Tool은 자동 실행 가능하도록 한다.
- 상태 변경이나 외부 영향이 있는 작업은 승인 정책을 적용한다.
- 모바일 앱 개발 전에 웹 Playground에서 Agent 전체 흐름을 충분히 검증한다.

---

## 4. 전체 아키텍처

```text
                  Web Playground
                        |
                        v
               Cloudflare Workers
                        |
                        v
              PersonalAssistantAgent
              Cloudflare Agents SDK
                        |
        +---------------+---------------+
        |               |               |
        v               v               v
      LLM          Durable Object      Tools
                    + SQLite        Gmail / Calendar
                                      Web Search
                        |
                        v
                Admin Web Console
```

향후 확장:

```text
iPhone / Apple Watch
        |
        | STT -> Text Command
        v
Cloudflare Personal Assistant Agent
        |
        v
Text Output / TTS Output
```

---

## 5. 권장 기술 스택

### Backend / Agent

- TypeScript
- Cloudflare Workers
- Cloudflare Agents SDK
- Durable Objects
- SQLite
- Cloudflare Secrets
- HTTP / WebSocket

### LLM

아래 중 하나를 초기 기본 모델로 선택한다.

- OpenAI API
- Anthropic API
- Google Gemini API
- Cloudflare Workers AI

LLM Provider는 교체 가능하도록 추상화한다.

### Web

- React
- TypeScript
- Vite 또는 Next.js
- Cloudflare Workers Static Assets 또는 Pages

### 외부 Tool

- Gmail API
- Google Calendar API
- Google OAuth 2.0
- Web Search API 또는 Cloudflare에서 사용 가능한 검색 방식

### 향후 모바일

- Swift
- SwiftUI
- URLSession
- Speech Framework 또는 별도 STT
- AVSpeechSynthesizer 또는 외부 TTS
- watchOS
- WatchConnectivity

---

# 6. MVP 개발 범위

## 6.1 Personal Assistant Agent

시스템의 핵심 Agent를 하나 생성한다.

### 주요 책임

- 사용자 명령 수신
- 대화 Context 구성
- Memory 조회
- LLM 호출
- Tool 선택 및 실행
- Tool 결과 해석
- 응답 생성
- 실행 History 저장
- 승인 필요 여부 판단
- Scheduler 등록 및 실행

### 기본 Agent

```text
PersonalAssistantAgent
```

1차 MVP에서는 Sub Agent를 사용하지 않는다.

---

## 6.2 Conversation

Agent는 사용자와의 대화 이력을 유지해야 한다.

### 저장 정보

- session_id
- role
- message
- created_at
- tool_call 여부
- tool_call 결과
- model 정보

### 요구사항

- 최근 대화 Context를 LLM에 제공한다.
- 세션별 대화를 조회할 수 있어야 한다.
- 관리자 웹에서 대화 History를 확인할 수 있어야 한다.
- 필요 시 특정 세션을 삭제할 수 있어야 한다.

---

## 6.3 Memory

Memory는 Conversation과 분리해서 관리한다.

### Memory 유형

#### Profile Memory

사용자의 기본 설정 및 장기적으로 변하지 않는 정보.

예:

- 기본 언어
- 시간대
- 응답 선호
- 기본 서비스 설정

#### Long-term Memory

Agent가 장기적으로 기억해야 하는 사용자 정보.

예:

- 일정 관련 선호
- 업무 방식
- 반복되는 사용자 결정
- 개인 규칙

### 요구사항

- Agent가 필요한 경우 Long-term Memory를 조회할 수 있어야 한다.
- 새로운 Memory 후보를 저장할 수 있어야 한다.
- 관리자 웹에서 Memory 조회/수정/삭제가 가능해야 한다.
- Memory에는 생성일과 수정일을 기록한다.
- Memory 저장 주체가 Agent인지 사용자인지 구분한다.

### 1차 제외

- Embedding
- Semantic Search
- Vector DB
- 자동 RAG Pipeline

---

## 6.4 Tool System

Agent가 외부 기능을 호출할 수 있어야 한다.

### 1차 Tool

#### Gmail

- 최근 메일 조회
- 특정 발신자 검색
- 키워드 검색
- 메일 본문 조회

메일 발송은 초기 구현 후 승인 기능과 함께 활성화한다.

#### Google Calendar

- 오늘 일정 조회
- 특정 날짜 일정 조회
- 기간별 일정 조회
- 일정 생성
- 일정 수정

삭제 기능은 승인 정책 적용 후 활성화한다.

#### Web Search

- 사용자 질문에 필요한 최신 정보 검색
- 검색 결과를 Agent Context에 전달

### Tool Interface 공통 규격

각 Tool은 최소한 다음 정보를 가진다.

- tool_name
- description
- input_schema
- execute()
- requires_approval
- execution_log

---

## 6.5 Approval

외부 상태를 변경하는 기능에는 승인 정책을 적용한다.

### 자동 실행 가능

- Gmail 조회
- Calendar 조회
- Web Search
- Memory 조회

### 기본 승인 필요

- 메일 발송
- Calendar 생성
- Calendar 수정
- Calendar 삭제
- Long-term Memory 삭제
- 외부 시스템 데이터 변경

### 승인 데이터

- approval_id
- action
- tool_name
- parameters
- status
- requested_at
- approved_at
- rejected_at

### Status

- pending
- approved
- rejected
- executed
- failed
- expired

### Phase 5 구현 아키텍처

Phase 5는 Tool Registry를 서버 측 실행 정책의 최종 경계로 사용한다. Tool은 `AUTO` 또는
`APPROVAL_REQUIRED` 정책을 가지며, 승인 실행 권한 없이 write Tool을 Registry에서 실행하려는
호출은 LLM이 생성한 호출인지 내부 호출인지와 관계없이 차단한다.

```text
LLM Tool Call
  -> Tool Registry policy check
  -> AUTO: immediate execution
  -> APPROVAL_REQUIRED: arguments snapshot + PENDING
  -> Approve API: conditional PENDING -> APPROVED claim
  -> saved arguments validation and execution
  -> EXECUTED or FAILED
```

Approval에는 conversation/request/tool-call correlation ID, Tool 이름과 인자 snapshot, 정책,
상태, 요청·해결·실행·만료 시간 및 결과 요약을 저장한다. 거부는 `REJECTED`, 승인 시점이
만료 시간을 지난 요청은 `EXPIRED`가 되며 두 상태 모두 실행할 수 없다. 승인 과정에서는
LLM을 다시 호출하거나 Tool 인자를 다시 생성하지 않는다.

Gmail `gmail.send`, `gmail.reply`와 Calendar `calendar.create`, `calendar.update`,
`calendar.delete`는 모두 승인이 필요하다. Calendar write payload에는 Profile Memory에서
결정한 IANA timezone을 사용하며, 시작·종료 시각은 UTC offset이 포함된 RFC3339 값만 받는다.

API 계약:

```text
GET  /api/approvals?status=PENDING
GET  /api/approvals/:id
POST /api/approvals/:id/approve
POST /api/approvals/:id/reject
```

모든 Endpoint는 기존 단일 사용자 Bearer 인증을 사용한다. OAuth token과 API Secret은 Approval,
Tool 실행 로그 및 Playground 응답에 포함하지 않는다. 메일 본문과 Calendar description은
실행 로그에서 길이 정보만 남기고 마스킹한다. OAuth 권한은 Gmail 조회용 `gmail.readonly`,
발송용 `gmail.send`, Calendar 일정 조회·쓰기용 `calendar.events`로 제한한다.

---

## 6.6 Scheduler

사용자가 Agent에게 미래 작업을 등록할 수 있어야 한다.

예:

```text
"내일 오전 10시에 이 일을 알려줘."
"매주 월요일 오전에 이번 주 일정 요약해줘."
```

### 기능

- 단발성 작업
- 반복 작업
- 작업 활성화/비활성화
- 작업 수정
- 작업 삭제
- 최근 실행 결과 저장

### 저장 정보

- schedule_id
- title
- instruction
- schedule_rule
- enabled
- last_run_at
- next_run_at
- created_at

---

## 6.7 History / Execution Log

Agent 실행을 추적할 수 있어야 한다.

### 저장 정보

- request
- response
- model
- tool_calls
- tool_results
- execution_time
- token usage
- success / failure
- error message
- created_at

### 목적

- Agent 오작동 분석
- Tool 실행 확인
- 비용 확인
- 응답 품질 확인

---

# 7. Web Playground

모바일 앱 개발 전 Agent 전체 기능을 테스트하기 위한 웹 화면을 개발한다.

## 필수 기능

- 텍스트 명령 입력
- Agent 응답 출력
- Conversation 표시
- Tool 호출 정보 표시
- Tool 결과 확인
- 오류 표시
- 응답 시간 표시
- 모델 정보 표시

## 음성 테스트

가능하면 초기 버전에 포함한다.

```text
Browser Microphone
      |
      v
     STT
      |
      v
Text Command
      |
      v
Agent
      |
      v
Text Response
      |
      v
     TTS
```

### 음성 기능

- 마이크 입력
- STT 변환 결과 표시
- Agent 요청
- 텍스트 응답
- TTS 재생

웹 Playground는 추후 Admin Web의 `Playground` 메뉴로 유지한다.

---

# 8. Admin Web

개인 Agent를 관리하는 Control Center 역할을 한다.

## 메뉴

### Dashboard

- 최근 요청
- 최근 Tool 실행
- Pending Approval
- Scheduler 상태
- 최근 오류

### Memory

- Profile Memory 조회/수정
- Long-term Memory 조회
- Memory 수정
- Memory 삭제
- Memory 직접 추가

### Tools

- Tool 활성화/비활성화
- Tool 권한 설정
- Google OAuth 연결 상태
- Tool별 Approval 정책

### Schedules

- Scheduler 목록
- 추가
- 수정
- 활성화/비활성화
- 삭제
- 최근 실행 결과

### Approvals

- Pending 목록
- 승인
- 거부
- 완료된 승인 History

### History

- Agent 요청/응답 조회
- Tool Call 조회
- 실행 시간
- 모델
- Token Usage
- 오류 확인

### Settings

- 기본 LLM Provider
- Model
- 언어
- Timezone
- System Prompt 관련 설정

### Playground

- Agent 직접 테스트
- Tool Call 확인
- 음성 입출력 테스트

---

# 9. 데이터 저장

1차 MVP에서는 별도 외부 DB를 사용하지 않는다.

## 저장소

```text
Cloudflare Durable Object
          |
          v
        SQLite
```

## 주요 데이터

- conversations
- messages
- memories
- tool_settings
- approvals
- schedules
- execution_history
- user_settings

구체적인 Schema는 별도의 DB Schema 문서로 작성한다.

---

# 10. 인증 및 보안

개인용 서비스라도 외부 공개 Endpoint를 그대로 노출하지 않는다.

## 요구사항

- Admin Web 인증
- Playground 인증
- Agent API 인증
- 외부 API Key는 Cloudflare Secrets에 저장
- API Key를 Browser나 향후 모바일 앱에 저장하지 않는다.
- Google OAuth Token은 서버 측에서 관리한다.
- Tool별 권한을 관리한다.
- 중요한 Tool은 Approval을 거친다.

1차 MVP에서는 Single User Authentication으로 충분하다.

---

# 11. API / Interface 개요

구체적인 URI는 구현 과정에서 변경 가능하다.

## Agent

```text
POST /api/agent/message
```

입력:

```json
{
  "message": "내일 오후 일정 알려줘",
  "sessionId": "client-session-id",
  "location": {
    "latitude": 37.5665,
    "longitude": 126.978,
    "accuracyMeters": 25,
    "capturedAt": "2026-08-13T00:00:00.000Z",
    "source": "browser"
  }
}
```

`location`은 선택 항목이다. Playground는 브라우저 위치 권한이 허용된 경우 각 Agent 요청에
현재 좌표를 전달하며, iPhone/Apple Watch Thin Client는 향후 동일 계약에서 `source`를
`ios`/`watchos`로 전달한다. 위치는 요청 시점의 임시 Context로만 사용하고 Profile/Long-term
Memory에 자동 저장하지 않는다. 권한 거부나 위치 조회 실패는 기본 Chat 실행을 막지 않는다.

응답:

```json
{
  "message": "내일 오후 일정은 2건입니다.",
  "toolCalls": [],
  "approvalRequired": false
}
```

## Memory

```text
GET    /api/memories
POST   /api/memories
PATCH  /api/memories/:id
DELETE /api/memories/:id
```

## Schedules

```text
GET    /api/schedules
POST   /api/schedules
PATCH  /api/schedules/:id
DELETE /api/schedules/:id
```

## Approvals

```text
GET  /api/approvals
POST /api/approvals/:id/approve
POST /api/approvals/:id/reject
```

## History

```text
GET /api/history
GET /api/history/:id
```

---

# 12. 향후 iPhone / Apple Watch

1차 MVP 완료 후 개발한다.

모바일 앱은 Thin Client를 원칙으로 한다.

## iPhone

```text
음성 입력
   |
   v
STT
   |
   v
Agent API
   |
   v
Text Output
   |
   +--> 화면 표시
   |
   +--> TTS
```

## Apple Watch

기능을 최소화한다.

- 음성 명령
- Agent 결과 표시
- 간단한 TTS 응답
- 필요한 경우 승인/거부

### 모바일에서 제외할 기능

- Memory 관리
- Tool 설정
- Scheduler 상세 관리
- 실행 History 상세 분석
- Agent 내부 설정

위 기능은 Admin Web에서 처리한다.

---

# 13. 개발 단계

## Phase 1. 프로젝트 초기화

- Cloudflare Workers 프로젝트
- Agents SDK 설정
- Durable Object 설정
- SQLite 저장 확인
- 기본 Agent 생성
- LLM 연결

완료 기준:

```text
Text -> Agent -> LLM -> Response
```

---

## Phase 2. Web Playground

- React Web 생성
- Agent 호출
- 대화 UI
- Tool Call Debug UI
- STT/TTS 테스트

완료 기준:

```text
Browser -> Agent -> Response
```

음성 포함 시:

```text
Voice -> STT -> Agent -> TTS
```

---

## Phase 3. Memory

- Conversation 저장
- Long-term Memory
- Profile Memory
- Memory CRUD

완료 기준:

- Agent 재접속 후에도 주요 Memory 유지
- Admin/API를 통한 Memory 수정 가능

---

## Phase 4. Tools

- Gmail
- Google Calendar
- Web Search
- OAuth

완료 기준:

- 자연어 명령으로 각 Tool 조회 성공
- Tool 결과를 기반으로 Agent 응답 생성

---

## Phase 5. Approval

- Tool Approval 정책
- Pending 상태
- 승인/거부
- 승인 후 Tool 재실행

완료 기준:

- 상태 변경 Tool이 승인 없이 실행되지 않음
- Pending 조회, 승인, 거부, 만료 및 중복 승인 차단 구현 완료
- Gmail send/reply와 Calendar create/update/delete 승인 실행 구현 완료
- Playground Approval Debug UI 구현 완료

---

## Phase 6. Scheduler

- 단발 Schedule
- 반복 Schedule
- 실행 결과 저장

완료 기준:

- 등록된 시간에 Agent 작업 실행

### Phase 6 구현 아키텍처

Scheduler는 `ScheduleRepository`, `SchedulerService`, 시간 계산 모듈 및 Agent의
`executeScheduledTask` callback으로 분리한다. Jarvis 일정 메타데이터와 실행 기록은 Durable
Object SQLite의 `schedules`, `schedule_executions`에 저장한다. 실제 wake-up은 Cloudflare Agents
SDK의 `schedule(Date, callback, payload)`가 제공하는 Durable Object Alarm을 사용한다.

반복 작업은 timezone이 없는 SDK cron 문자열에 직접 의존하지 않는다. `daily` 또는 `weekly`
규칙과 IANA timezone을 저장하고, 실행 완료 후 Scheduler 레이어가 다음 로컬 wall-clock 시각을
계산해 다음 one-time Alarm을 등록한다. Profile Memory timezone을 기본값으로 사용하며 요청에
명시된 timezone이 우선한다.

실행은 조건부 `scheduled/failed -> running` 전이로 claim하여 중복 실행을 막는다. 단발 작업은
`completed`, 반복 작업은 다음 실행 시각과 함께 `scheduled`로 돌아간다. 실패한 반복 작업도
삭제하지 않고 다음 Alarm을 유지한다. 예약 실행은 기존 Agent message/Tool Registry를 그대로
통과하므로 write Tool은 실행 시점에 Pending Approval만 만들고 승인 전 외부 상태를 변경하지 않는다.

---

## Phase 7. Admin Web

- Dashboard
- Memory
- Tools
- Schedules
- Approvals
- History
- Settings
- Playground 통합

### Phase 7 구현 아키텍처

`admin/`은 React, TypeScript, Vite 기반의 단일 사용자 Control Center다. Dashboard, Memory,
Tools, Approvals, Schedules, History, Settings 및 기존 Playground 링크를 제공한다. API 호출은
공통 service 계층을 통하며 production URL이나 Secret을 브라우저 코드에 하드코딩하지 않는다.

Backend에는 기존 기능을 중복하지 않고 다음 관리 조회 계약만 추가한다.

```text
GET /api/admin/dashboard
GET /api/tools
GET /api/history
GET /api/history/:id
GET/PATCH /api/settings
```

Tool enable/disable 저장 모델은 현재 Backend에 없으므로 Admin Tools 화면은 실제 연결·정책·최근
실행 상태만 조회한다. LLM Provider와 Model은 Cloudflare 환경변수 관리 항목으로 읽기 전용이며,
Admin에서는 Profile Memory 기반 language와 timezone 외에 Agent의 응답 톤, 한국어 말투,
답변 상세도 및 사용자 지정 답변 지침을 수정한다. 이 응답 설정은 Durable Object SQLite의
Profile Memory에 저장되고 다음 Agent 요청부터 system prompt에 반영된다. 사용자 지정 지침은
4,000자로 제한하며 안전성, 정확성, Tool Policy 및 현재 사용자 요청보다 우선하지 않는다.
Token Usage는 현재 LLM 계약이 저장하지 않으므로 History에 `Unavailable`로 표시하며 값을 생성하지 않는다.

로컬에서는 Vite server proxy, Cloudflare Pages 배포에서는 `functions/api/[[path]].ts`가 서버 측
Bearer Token을 주입한다. 브라우저 번들에는 API Token이 포함되지 않는다. 배포된 Admin 전체는
Cloudflare Access의 Single User 정책으로 보호한다. 기존 `web/` Playground는 복사하지 않고
설정된 URL로 이동한다.

---

## Phase 8. iPhone / Apple Watch

MVP Agent 안정화 이후 별도 프로젝트로 진행한다.

---

# 14. 1차 MVP 제외 범위

다음 기능은 1차 MVP에서 개발하지 않는다.

- Vector DB
- Embedding
- RAG 문서 검색
- 외부 일반 DB
- Sub Agent
- Multi-Agent orchestration
- Agent가 직접 Tool 생성
- Browser Automation
- 복잡한 Workflow Engine
- Wake Word
- iPhone 앱
- Apple Watch 앱
- 멀티 사용자
- 결제
- SaaS 기능

---

# 15. 비기능 요구사항

## 유지보수성

- LLM Provider 교체 가능
- Tool 추가 가능
- STT/TTS Provider 교체 가능
- Tool과 Agent 핵심 로직을 분리

## 로깅

- 모든 Tool Call 기록
- Agent 오류 기록
- LLM 사용량 기록

## 보안

- Secret은 Cloudflare Secrets 사용
- 클라이언트에 외부 API Key 노출 금지
- 상태 변경 Tool은 Approval 적용
- 장기 Infrastructure Secret과 런타임 OAuth Credential을 분리한다.
- Provider와 MCP Registry는 실제 인증정보 대신 credential reference만 저장한다.
- Runtime Configuration, Change History, Health, Fallback 이력에는 Secret 값을 저장하지 않는다.
- 인증 상태와 Provider health 상태를 별도로 관리한다.
- OAuth 연결과 해제는 사용자의 명시적인 요청과 사용자 consent를 요구한다.

## 장애 대응

- Tool 실패 시 전체 Agent 요청이 비정상 종료되지 않아야 한다.
- Tool 오류 내용을 Agent가 사용자에게 이해 가능한 형태로 반환한다.
- Scheduler 실패 기록을 저장한다.
- Model, Tool Provider, MCP 연결 상태는 `healthy`, `degraded`, `unavailable`, `unknown`으로 조회한다.
- Fallback은 사용자 설정이 있는 경우에만 timeout, network, rate-limit, 5xx 오류에 대해 한 단계만 수행한다.
- Fallback 실행은 active Provider를 변경하지 않으며 별도 실행 이력으로 기록한다.
- 인증, 권한, 입력 검증 오류에는 fallback을 수행하지 않는다.
- 상태 변경 Tool은 외부 반영 여부가 불확실할 수 있으므로 fallback으로 재실행하지 않는다.

---

# 16. MVP 완료 기준

다음 시나리오가 모두 동작하면 1차 MVP가 완료된 것으로 본다.

### 대화

```text
"오늘 할 일을 정리해줘"
-> Agent 응답
```

### Memory

```text
"앞으로 일정은 한국 시간 기준으로 알려줘."
-> Memory 저장
-> 이후 대화에 반영
```

### Gmail

```text
"오늘 받은 중요한 메일 찾아줘."
-> Gmail 조회
-> Agent 요약
```

### Calendar

```text
"내일 오후 일정 알려줘."
-> Calendar 조회
-> Agent 응답
```

### Approval

```text
"내일 3시에 회의 일정 만들어줘."
-> Approval 요청
-> 승인
-> Calendar 생성
```

### Scheduler

```text
"내일 오전 9시에 오늘 일정 알려줘."
-> Schedule 생성
-> 지정 시간 실행
```

### Admin

- Memory 수정 가능
- Tool 설정 확인 가능
- Schedule 관리 가능
- Approval 처리 가능
- History 조회 가능

### Playground

- Text Agent 요청 가능
- Tool Call 확인 가능
- STT/TTS 테스트 가능

---

# 17. 최종 MVP 구조

```text
                 +-------------------+
                 |   Admin Web       |
                 |-------------------|
                 | Memory            |
                 | Tools             |
                 | Scheduler         |
                 | Approval          |
                 | History           |
                 | Playground        |
                 +---------+---------+
                           |
                           v
                +----------------------+
                | Cloudflare Workers   |
                | Personal Assistant   |
                | Agent                |
                +----------+-----------+
                           |
          +----------------+----------------+
          |                |                |
          v                v                v
        LLM        Durable Object        Tools
                    + SQLite         Gmail / Calendar
                                      Web Search
```

향후:

```text
iPhone / Apple Watch
        |
        | STT
        v
Cloudflare Personal Assistant
        |
        v
Text / TTS Output
```

---

# 18. 개발 우선순위 요약

```text
1. Agent
2. Playground
3. Memory
4. Tools
5. Approval
6. Scheduler
7. Admin Web
8. iPhone
9. Apple Watch
```

1차 목표는 모바일 앱이 아니라 **Cloudflare Personal Assistant Agent 자체의 기능과 안정성을 Web Playground에서 검증하는 것**이다.
