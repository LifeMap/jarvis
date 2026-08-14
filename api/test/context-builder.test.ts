import { describe, expect, it } from "vitest";
import { ContextBuilder } from "../src/context/context-builder";

describe("ContextBuilder", () => {
  it("orders profile, long-term memory, recent conversation, and current message", () => {
    const request = new ContextBuilder().build({
      profile: [{ id: "profile:timezone", type: "profile", key: "timezone", value: "Asia/Seoul", source: "user", createdAt: "now", updatedAt: "now" }],
      longTerm: [{ id: "memory-1", type: "long_term", content: "일정은 한국 시간 기준", category: "preference", source: "user", createdAt: "now", updatedAt: "now" }],
      conversation: [{ messageId: "m1", sessionId: "s1", role: "user", content: "내 이름은 테스트 사용자야", model: null, toolCalls: null, toolResult: null, createdAt: "now" }],
      currentMessage: "아까 내가 뭐라고 했지?",
    });

    expect(request.systemPrompt).toContain("timezone: Asia/Seoul");
    expect(request.systemPrompt).toContain("일정은 한국 시간 기준");
    expect(request.messages).toEqual([
      { role: "user", content: "내 이름은 테스트 사용자야" },
      { role: "user", content: "아까 내가 뭐라고 했지?" },
    ]);
  });

  it("applies owner-configured tone, speech style, detail and custom instructions", () => {
    const profile = [
      ["assistant_tone", "warm"],
      ["assistant_speech_style", "casual"],
      ["assistant_response_detail", "detailed"],
      ["assistant_custom_instructions", "항상 결론부터 말해줘."],
    ].map(([key, value]) => ({ id: `profile:${key}`, type: "profile" as const, key: key!, value: value!, source: "user" as const, createdAt: "now", updatedAt: "now" }));
    const request = new ContextBuilder().build({ profile, longTerm: [], conversation: [], currentMessage: "안녕" });
    expect(request.systemPrompt).toContain("warm and empathetic");
    expect(request.systemPrompt).toContain("casual Korean speech");
    expect(request.systemPrompt).toContain("thorough explanations");
    expect(request.systemPrompt).toContain("항상 결론부터 말해줘.");
    expect(request.systemPrompt).not.toContain("Profile memory:\n- assistant_tone");
  });
});
