# Phase 5 CHECKPOINT 1 — Jarvis ephemeral Realtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bridge가 Jarvis API로 ephemeral Realtime client secret을 받아 OpenAI WebSocket에 붙는다. `OPENAI_API_KEY`는 앱 connect에 쓰지 않는다.

**Architecture:** Worker `POST /api/realtime/client-secret`이 OpenAI `POST /v1/realtime/client_secrets`를 대행한다. Bridge는 `.env`의 `JARVIS_API_TOKEN`/`JARVIS_API_ORIGIN`으로 mint한 뒤 adapter Bearer만 바꾼다. `session.update`·PCM·barge-in은 Phase 4 그대로다.

**Tech Stack:** Cloudflare Worker (`api/`, vitest), Swift 6 / SwiftPM (`bridge/`, XCTest). 드라이버 수정 없음.

**스펙:** `docs/superpowers/specs/2026-08-24-phase5-cp1-jarvis-ephemeral-realtime-design.md`

작업 디렉터리: `/Volumes/Dev/workspaces/twms/jarvis`  
테스트: `cd api && npm test` · `cd bridge && swift test --filter <TestClass>`

**바꾸면 안 되는 것:** PCM/mute/barge-in, session.update VAD, Realtime 실패로 route 롤백, Keychain, Tool/Memory/Approval, 드라이버.

---

## File map

| 파일 | 역할 |
|---|---|
| `docs/Call_Bridge_v2_Phase_5_Report.md` | CP1 계획 경로 |
| `api/src/realtime/client-secret.ts` | OpenAI mint + 응답 정규화 |
| `api/src/index.ts` | `POST /api/realtime/client-secret` |
| `api/test/realtime-client-secret.test.ts` | mint/라우트 테스트 |
| `bridge/.../RealtimeEnvFile.swift` | Jarvis origin/token |
| `bridge/.../JarvisAPIClient.swift` | mint HTTP |
| `bridge/.../OpenAIRealtimeVoiceSessionController.swift` | connect가 mint 사용 |
| Bridge 테스트 | env, client, session |

---

### Task 1: 리포트에 계획 경로

**Files:**
- Modify: `docs/Call_Bridge_v2_Phase_5_Report.md`

- [ ] **Step 1:** 스펙 줄 아래에 계획을 추가한다.

```markdown
계획(CP1): `docs/superpowers/plans/2026-08-24-phase5-cp1-jarvis-ephemeral-realtime.md`
```

- [ ] **Step 2: Commit**

```bash
git add docs/Call_Bridge_v2_Phase_5_Report.md docs/superpowers/plans/2026-08-24-phase5-cp1-jarvis-ephemeral-realtime.md
git commit -m "docs: add Phase 5 CP1 implementation plan"
```

---

### Task 2: mintRealtimeClientSecret (TDD)

**Files:**
- Create: `api/src/realtime/client-secret.ts`
- Create: `api/test/realtime-client-secret.test.ts`

- [ ] **Step 1:** 실패하는 테스트. `fetch`를 mock한다.

```ts
import { afterEach, describe, expect, it, vi } from "vitest";
import { mintRealtimeClientSecret } from "../src/realtime/client-secret";

afterEach(() => vi.unstubAllGlobals());

describe("mintRealtimeClientSecret", () => {
  it("returns value expiresAt model from OpenAI", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(JSON.stringify({
      value: "ek_test",
      expires_at: 1_700_000_000,
      session: { model: "gpt-realtime-2.1-mini" },
    }), { status: 200 })));
    await expect(mintRealtimeClientSecret({
      openaiAPIKey: "sk-server",
      baseURL: "https://api.openai.com/v1",
      model: "gpt-realtime-2.1-mini",
    })).resolves.toEqual({
      value: "ek_test",
      expiresAt: 1_700_000_000,
      model: "gpt-realtime-2.1-mini",
    });
    const call = (fetch as ReturnType<typeof vi.fn>).mock.calls[0];
    expect(call[0]).toBe("https://api.openai.com/v1/realtime/client_secrets");
    expect((call[1] as RequestInit).headers).toMatchObject({
      authorization: "Bearer sk-server",
    });
    const body = JSON.parse(String((call[1] as RequestInit).body));
    expect(body.expires_after).toEqual({ anchor: "created_at", seconds: 600 });
    expect(body.session).toEqual({ type: "realtime", model: "gpt-realtime-2.1-mini" });
    expect(body.session.turn_detection).toBeUndefined();
  });

  it("throws when OpenAI key is missing", async () => {
    await expect(mintRealtimeClientSecret({
      openaiAPIKey: "",
      baseURL: "https://api.openai.com/v1",
      model: "gpt-realtime-2.1-mini",
    })).rejects.toThrow(/OPENAI_API_KEY/);
  });

  it("throws a redacted error when OpenAI fails", async () => {
    vi.stubGlobal("fetch", vi.fn(async () => new Response(
      JSON.stringify({ error: { message: "invalid_api_key ek_should_not_leak" } }),
      { status: 401 },
    )));
    await expect(mintRealtimeClientSecret({
      openaiAPIKey: "sk-server",
      baseURL: "https://api.openai.com/v1",
      model: "gpt-realtime-2.1-mini",
    })).rejects.toThrow(/Realtime credential/);
    try {
      await mintRealtimeClientSecret({
        openaiAPIKey: "sk-server",
        baseURL: "https://api.openai.com/v1",
        model: "gpt-realtime-2.1-mini",
      });
    } catch (error) {
      expect(String(error)).not.toContain("ek_should_not_leak");
    }
  });
});
```

- [ ] **Step 2:** `cd api && npm test -- realtime-client-secret`  
Expected: FAIL — 모듈 없음.

- [ ] **Step 3:** `api/src/realtime/client-secret.ts`를 최소 구현한다. `redactText`/`safeErrorMessage` 사용.

- [ ] **Step 4:** 같은 필터 PASS.

- [ ] **Step 5: Commit**

```bash
git add api/src/realtime/client-secret.ts api/test/realtime-client-secret.test.ts
git commit -m "feat: mint OpenAI Realtime client secrets on the server"
```

---

### Task 3: Worker 라우트 (TDD)

**Files:**
- Modify: `api/src/index.ts`
- Modify: `api/test/realtime-client-secret.test.ts` 또는 `api/test/worker.test.ts`

- [ ] **Step 1:** handler.fetch로 401 / 성공 / 503을 고정한다. 성공 시 `vi.stubGlobal("fetch")`.

- [ ] **Step 2:** FAIL — 404.

- [ ] **Step 3:** `isAuthorized` 뒤에 `POST /api/realtime/client-secret`을 넣는다. 모델은 body.model 또는 `gpt-realtime-2.1-mini`. 실패는 503, detail은 redacted.

- [ ] **Step 4:** `npm test` PASS.

- [ ] **Step 5: Commit**

```bash
git add api/src/index.ts api/test/realtime-client-secret.test.ts
git commit -m "feat: expose POST /api/realtime/client-secret"
```

---

### Task 4: RealtimeEnvFile Jarvis 필드 (TDD)

**Files:**
- Modify: `bridge/Sources/JarvisCallBridge/Realtime/RealtimeEnvFile.swift`
- Modify: `bridge/Tests/JarvisCallBridgeTests/RealtimeEnvFileTests.swift`
- Modify: `bridge/.env.example`

- [ ] **Step 1:** `JARVIS_API_TOKEN` / `JARVIS_API_ORIGIN` 로드 테스트를 추가한다.

- [ ] **Step 2:** `swift test --filter RealtimeEnvFileTests` FAIL.

- [ ] **Step 3:** `RealtimeEnvValues`에 필드를 넣고 load/resolve에 병합한다. process가 file보다 우선.

- [ ] **Step 4:** PASS.

- [ ] **Step 5: Commit**

```bash
git add bridge/Sources/JarvisCallBridge/Realtime/RealtimeEnvFile.swift \
  bridge/Tests/JarvisCallBridgeTests/RealtimeEnvFileTests.swift \
  bridge/.env.example
git commit -m "feat: load Jarvis API origin and token from .env"
```

---

### Task 5: JarvisAPIClient (TDD)

**Files:**
- Create: `bridge/Sources/JarvisCallBridge/Realtime/JarvisAPIClient.swift`
- Create: `bridge/Tests/JarvisCallBridgeTests/JarvisAPIClientTests.swift`

- [ ] **Step 1:** URLProtocol 또는 주입 `session` 스파이로 POST path, Bearer, 200 decode, 401 `jarvisAuth`, 그 외 `network`를 고정한다.

- [ ] **Step 2:** FAIL.

- [ ] **Step 3:** `mintRealtimeClientSecret(origin:token:model:)` 구현.

- [ ] **Step 4:** PASS.

- [ ] **Step 5: Commit**

```bash
git add bridge/Sources/JarvisCallBridge/Realtime/JarvisAPIClient.swift \
  bridge/Tests/JarvisCallBridgeTests/JarvisAPIClientTests.swift
git commit -m "feat: mint Realtime secrets through Jarvis API"
```

---

### Task 6: 세션 connect가 mint 사용 (TDD)

**Files:**
- Modify: `bridge/Sources/JarvisCallBridge/Realtime/OpenAIRealtimeVoiceSessionController.swift`
- Modify: `bridge/Tests/JarvisCallBridgeTests/OpenAIRealtimeVoiceSessionControllerTests.swift`

- [ ] **Step 1:** `testMissingJarvisAuthFailsWithoutAdapterConnect`, `testMintFailureDoesNotStopPCM`, `testConnectMintsSecretBeforeAdapterConnect`. 기존 `missing API key` 테스트는 Jarvis auth로 바꾼다. makeSession에 mint 스파이를 넣는다.

- [ ] **Step 2:** FAIL.

- [ ] **Step 3:** connect는 token/origin 검사 → mint → adapter에 `value` 전달. OpenAI env 키는 쓰지 않음. 401 → `jarvis auth`, 그 외 mint 실패 → `network`.

- [ ] **Step 4:** `swift test --filter OpenAIRealtimeVoiceSessionControllerTests` 및 기존 Realtime 필터 PASS.

- [ ] **Step 5: Commit**

```bash
git add bridge/Sources/JarvisCallBridge/Realtime/OpenAIRealtimeVoiceSessionController.swift \
  bridge/Tests/JarvisCallBridgeTests/OpenAIRealtimeVoiceSessionControllerTests.swift
git commit -m "feat: connect Realtime with a Jarvis-minted client secret"
```

---

### Task 7: 전체 스위트 + 리포트

- [ ] **Step 1:** `cd api && npm test` 그리고 `cd bridge && swift test`. 실패 0.

- [ ] **Step 2:** Phase 5 리포트 자동화 줄에 통과 수를 적는다. 실기기 PASS / Phase 5 COMPLETE를 선언하지 않는다.

- [ ] **Step 3: Commit**

```bash
git add docs/Call_Bridge_v2_Phase_5_Report.md
git commit -m "test: record Phase 5 CP1 automated coverage"
```

---

### Task 8: 배포 + 앱 빌드 (실통화는 사용자)

- [ ] `cd api && npm run deploy` (사용자가 배포를 막으면 중지하고 알린다)
- [ ] `bridge/Scripts/build-app.sh` — 드라이버 재설치 없음
- [ ] `bridge/.env`에서 `OPENAI_API_KEY`를 쓰지 않는지 확인 (파일 내용은 커밋하지 않음)

에이전트는 실전화를 걸지 않는다. 실기기 Connected는 사용자 확인 뒤에만 PASS.
