# Phase 5 CHECKPOINT 2 — Incoming Call Report Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 착신 종료 후 발신자·전사·merged m4a를 Jarvis `/api/calls`에 남기고, Playground 알림과 Admin `통화`에서 본다.

**Architecture:** Bridge는 Connected에서 통화를 만들고 Idle에서 믹스·인코딩 후 Worker로 올린다. Worker는 DO SQLite + R2(`CALLS_BUCKET`)에 저장한다. 요약은 전사가 있을 때만 LLM. Playground는 폴링 배너, Admin은 신규 메뉴.

**Tech Stack:** Cloudflare Worker + R2, Swift 6, React admin/web, vitest/XCTest.

**스펙:** `docs/superpowers/specs/2026-08-24-phase5-cp2-incoming-call-report-design.md`

**바꾸면 안 되는 것:** PCM/mute/barge-in, session.update VAD, route 롤백, 드라이버, 메일/발신/앱푸시, 채팅 세션에 보고 삽입.

작업 디렉터리: `/Volumes/Dev/workspaces/twms/jarvis`

## File map

| 파일 | 역할 |
|---|---|
| `api/src/calls/*` | 레코드·요약·R2 키 |
| `api/src/index.ts` | `/api/calls` 라우트 |
| `api/src/personal-assistant-agent.ts` | DO 메서드 |
| `api/wrangler.jsonc` | `CALLS_BUCKET` |
| `bridge/.../CallCallerIdentity.swift` | 번호 추출 + 연락처 이름 |
| `bridge/.../JarvisAPIClient.swift` | create/upload/complete |
| `bridge/.../OpenAIRealtimeVoiceAdapter.swift` | 전사 수집 |
| `bridge/.../OpenAIRealtimeVoiceSessionController.swift` | create + Idle 보고 |
| `bridge/.../CallAudioMixer.swift` | RX/TX 믹스 |
| `web/src` | 폴링 배너 |
| `admin/src` | `통화` 메뉴 |

커밋은 사용자가 요청할 때만 한다.

---

### Task 1: API calls + R2 (TDD)
### Task 2: Bridge caller + client + session report (TDD)
### Task 3: Playground 배너 + Admin 통화 (TDD)
### Task 4: 자동화 전체 통과, 리포트 갱신. 실기기는 사용자 확인 전 PASS 선언 금지.
