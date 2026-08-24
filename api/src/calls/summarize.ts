import type { ModelProvider } from "../llm/types";
import type { CallTranscriptTurn } from "./types";

export async function summarizeCallTranscript(
  transcript: CallTranscriptTurn[],
  provider: ModelProvider,
): Promise<string | null> {
  if (transcript.length === 0) return null;
  const lines = transcript.map((turn) => `${turn.role === "caller" ? "상대" : "Jarvis"}: ${turn.text}`).join("\n");
  const response = await provider.generate({
    systemPrompt: "전화 자동응답 전사를 짧은 한국어 용건으로만 요약한다. 없는 사실은 만들지 않는다. 한두 문장.",
    messages: [{ role: "user", content: lines }],
  });
  const text = response.text.trim();
  return text.length > 0 ? text.slice(0, 500) : null;
}
