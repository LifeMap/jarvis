import { describe, expect, it } from "vitest";
import { env, exports } from "cloudflare:workers";
import type { Env } from "../src/env";
import { summarizeCallTranscript } from "../src/calls/summarize";
import { callAudioObjectKey } from "../src/calls/types";
import { TestLlmProvider } from "../src/llm/test-provider";

type TestHandler = {
  fetch(request: Request, env: Env): Promise<Response>;
};

const handler = (exports as unknown as { default: TestHandler }).default;
const testEnv = env as unknown as Env;

function auth(init: RequestInit = {}): RequestInit {
  return {
    ...init,
    headers: {
      authorization: "Bearer test-token",
      ...(init.body ? { "content-type": "application/json" } : {}),
      ...init.headers,
    },
  };
}

async function createCall(
  caller = { name: "unknown", phoneNumber: "+821012345678" },
  direction?: "incoming" | "outgoing",
) {
  const response = await handler.fetch(new Request("https://example.test/api/calls", auth({
    method: "POST",
    body: JSON.stringify({ caller, startedAt: "2026-08-24T09:52:59.000Z", ...(direction ? { direction } : {}) }),
  })), testEnv);
  expect(response.status).toBe(200);
  return response.json<{ id: string; status: string; caller: typeof caller; direction: string }>();
}

describe("summarizeCallTranscript", () => {
  it("returns null without calling the model when transcript is empty", async () => {
    let called = false;
    const provider = new TestLlmProvider("should-not-run");
    provider.generate = async () => {
        called = true;
        return { text: "nope", model: "test" };
    };
    await expect(summarizeCallTranscript([], provider)).resolves.toBeNull();
    expect(called).toBe(false);
  });

  it("returns the model text for a transcript", async () => {
    await expect(summarizeCallTranscript(
      [{ role: "caller", text: "금요일 회의를 4시로 옮겨 주세요" }],
      new TestLlmProvider("회의 시간 변경 요청"),
    )).resolves.toBe("회의 시간 변경 요청");
  });
});

describe("callAudioObjectKey", () => {
  it("names an incoming folder with the caller number", () => {
    expect(callAudioObjectKey({
      startedAt: "2026-08-24T09:52:59.123Z",
      direction: "incoming",
      phoneNumber: "+821012345678",
    })).toBe("jarvis-call/R_20260824185259_+821012345678/merged.m4a");
  });

  it("names an outgoing folder with the recipient number", () => {
    expect(callAudioObjectKey({
      startedAt: "2026-08-24T09:52:59.123Z",
      direction: "outgoing",
      phoneNumber: "+82109990000",
    })).toBe("jarvis-call/S_20260824185259_+82109990000/merged.m4a");
  });

  it("strips slashes from phone numbers so the key stays one folder", () => {
    expect(callAudioObjectKey({
      startedAt: "2026-08-24T09:52:59.000Z",
      direction: "incoming",
      phoneNumber: "+82/10/1111",
    })).toBe("jarvis-call/R_20260824185259_+82101111/merged.m4a");
  });

  it("adds +82 only when the number is a domestic 0-prefix", () => {
    expect(callAudioObjectKey({
      startedAt: "2026-08-24T09:52:59.000Z",
      direction: "incoming",
      phoneNumber: "01012345678",
    })).toBe("jarvis-call/R_20260824185259_+821012345678/merged.m4a");
  });

  it("does not invent a country code for unknown", () => {
    expect(callAudioObjectKey({
      startedAt: "2026-08-24T09:52:59.000Z",
      direction: "incoming",
      phoneNumber: "unknown",
    })).toBe("jarvis-call/R_20260824185259_unknown/merged.m4a");
  });
});

describe("POST /api/calls", () => {
  it("rejects unauthenticated requests", async () => {
    const response = await handler.fetch(new Request("https://example.test/api/calls", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ caller: { name: "unknown", phoneNumber: "unknown" }, startedAt: "2026-08-24T09:52:59.000Z" }),
    }), testEnv);
    expect(response.status).toBe(401);
  });

  it("creates an active call with caller name and phone", async () => {
    const body = await createCall({ name: "김민수", phoneNumber: "+821011122233" });
    expect(body.status).toBe("active");
    expect(body.direction).toBe("incoming");
    expect(body.caller).toEqual({ name: "김민수", phoneNumber: "+821011122233" });
    expect(body.id).toMatch(/^call-/);
  });

  it("rejects an invalid direction", async () => {
    const response = await handler.fetch(new Request("https://example.test/api/calls", auth({
      method: "POST",
      body: JSON.stringify({
        caller: { name: "unknown", phoneNumber: "+821011122233" },
        startedAt: "2026-08-24T09:52:59.000Z",
        direction: "sideways",
      }),
    })), testEnv);
    expect(response.status).toBe(400);
  });
});

describe("call audio and complete", () => {
  it("uploads audio, lists without transcript, and completes with a summary", async () => {
    const created = await createCall();
    const put = await handler.fetch(new Request(`https://example.test/api/calls/${created.id}/audio`, {
      method: "PUT",
      headers: { authorization: "Bearer test-token", "content-type": "audio/mp4" },
      body: new Uint8Array([1, 2, 3, 4]),
    }), testEnv);
    expect(put.status).toBe(200);
    await expect(put.json()).resolves.toEqual({ hasAudio: true });
    const stored = await testEnv.CALLS_BUCKET!.get("jarvis-call/R_20260824185259_+821012345678/merged.m4a");
    expect(stored).not.toBeNull();
    expect(new Uint8Array(await stored!.arrayBuffer())).toEqual(new Uint8Array([1, 2, 3, 4]));

    const listed = await handler.fetch(new Request("https://example.test/api/calls", auth()), testEnv);
    const listBody = await listed.json<{ calls: Array<{ id: string; hasAudio: boolean; transcript?: unknown }> }>();
    const item = listBody.calls.find((call) => call.id === created.id);
    expect(item?.hasAudio).toBe(true);
    expect(item).not.toHaveProperty("transcript");

    const complete = await handler.fetch(new Request(`https://example.test/api/calls/${created.id}/complete`, auth({
      method: "POST",
      body: JSON.stringify({
        endedAt: "2026-08-24T09:53:21.000Z",
        transcript: [{ role: "caller", text: "택배 왔습니다" }],
      }),
    })), testEnv);
    expect(complete.status).toBe(200);
    const completed = await complete.json<{
      status: string;
      summary: string | null;
      audioPath: string | null;
      transcript: unknown[];
    }>();
    expect(completed.status).toBe("completed");
    expect(completed.summary).toBe("안녕하세요. Jarvis 테스트 응답입니다.");
    expect(completed.audioPath).toBe(`/api/calls/${created.id}/audio`);
    expect(completed.transcript).toEqual([{ role: "caller", text: "택배 왔습니다" }]);

    const audio = await handler.fetch(new Request(`https://example.test/api/calls/${created.id}/audio`, auth()), testEnv);
    expect(audio.status).toBe(200);
    expect(audio.headers.get("content-type")).toBe("audio/mp4");
    expect(new Uint8Array(await audio.arrayBuffer())).toEqual(new Uint8Array([1, 2, 3, 4]));
    expect(JSON.stringify(completed)).not.toContain("ek_");
  });

  it("stores outgoing audio under the recipient number", async () => {
    const created = await createCall({ name: "unknown", phoneNumber: "+82109990000" }, "outgoing");
    expect(created.direction).toBe("outgoing");
    const put = await handler.fetch(new Request(`https://example.test/api/calls/${created.id}/audio`, {
      method: "PUT",
      headers: { authorization: "Bearer test-token", "content-type": "audio/mp4" },
      body: new Uint8Array([5, 6]),
    }), testEnv);
    expect(put.status).toBe(200);
    const stored = await testEnv.CALLS_BUCKET!.get("jarvis-call/S_20260824185259_+82109990000/merged.m4a");
    expect(stored).not.toBeNull();
  });

  it("does not invent a summary when transcript is empty", async () => {
    const created = await createCall();
    const complete = await handler.fetch(new Request(`https://example.test/api/calls/${created.id}/complete`, auth({
      method: "POST",
      body: JSON.stringify({ endedAt: "2026-08-24T09:53:21.000Z", transcript: [] }),
    })), testEnv);
    const body = await complete.json<{ status: string; summary: string | null }>();
    expect(body.summary).toBeNull();
    expect(body.status).toBe("upload_failed");
  });

  it("stores an allowed client summary and stays failed when transcript is empty", async () => {
    const created = await createCall({ name: "unknown", phoneNumber: "+821011122233" }, "outgoing");
    const complete = await handler.fetch(new Request(`https://example.test/api/calls/${created.id}/complete`, auth({
      method: "POST",
      body: JSON.stringify({
        endedAt: "2026-08-24T09:53:21.000Z",
        transcript: [],
        uploadFailed: true,
        summary: "콜백 연결 안 됨",
      }),
    })), testEnv);
    expect(complete.status).toBe(200);
    const body = await complete.json<{ status: string; summary: string | null; hasAudio: boolean }>();
    expect(body.status).toBe("failed");
    expect(body.summary).toBe("콜백 연결 안 됨");
    expect(body.hasAudio).toBe(false);
  });

  it("stores 번호 없음 the same way", async () => {
    const created = await createCall({ name: "unknown", phoneNumber: "unknown" }, "outgoing");
    const complete = await handler.fetch(new Request(`https://example.test/api/calls/${created.id}/complete`, auth({
      method: "POST",
      body: JSON.stringify({
        endedAt: "2026-08-24T09:53:21.000Z",
        transcript: [],
        uploadFailed: true,
        summary: "번호 없음",
      }),
    })), testEnv);
    const body = await complete.json<{ status: string; summary: string | null }>();
    expect(body.status).toBe("failed");
    expect(body.summary).toBe("번호 없음");
  });

  it("ignores a client summary that is not one of the two fixed phrases", async () => {
    const created = await createCall();
    const complete = await handler.fetch(new Request(`https://example.test/api/calls/${created.id}/complete`, auth({
      method: "POST",
      body: JSON.stringify({
        endedAt: "2026-08-24T09:53:21.000Z",
        transcript: [],
        summary: "알아서 요약해",
      }),
    })), testEnv);
    const body = await complete.json<{ status: string; summary: string | null }>();
    expect(body.summary).toBeNull();
    expect(body.status).toBe("upload_failed");
  });

  it("rejects a second audio upload after complete", async () => {
    const created = await createCall();
    await handler.fetch(new Request(`https://example.test/api/calls/${created.id}/complete`, auth({
      method: "POST",
      body: JSON.stringify({ endedAt: "2026-08-24T09:53:21.000Z", transcript: [{ role: "jarvis", text: "네" }] }),
    })), testEnv);
    const put = await handler.fetch(new Request(`https://example.test/api/calls/${created.id}/audio`, {
      method: "PUT",
      headers: { authorization: "Bearer test-token", "content-type": "audio/mp4" },
      body: new Uint8Array([9]),
    }), testEnv);
    expect(put.status).toBe(409);
  });

  it("returns 404 for an unknown call", async () => {
    const response = await handler.fetch(new Request("https://example.test/api/calls/call-missing", auth()), testEnv);
    expect(response.status).toBe(404);
  });
});
