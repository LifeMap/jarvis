import type { ConversationMessage, LongTermMemory, ProfileMemory } from "../contracts";
import type { LlmMessage, LlmRequest } from "../llm/types";

const BASE_SYSTEM_PROMPT = [
  "You are Jarvis, a private personal AI assistant for one user.",
  "Respond clearly and concisely in the language used by the user.",
  "Do not claim to have used tools or data sources that were not provided.",
].join(" ");

const RESPONSE_SETTING_KEYS = new Set(["assistant_tone", "assistant_speech_style", "assistant_response_detail", "assistant_custom_instructions"]);
const TONE_PROMPTS: Record<string, string> = { friendly: "friendly and approachable", professional: "professional and composed", warm: "warm and empathetic", direct: "direct and matter-of-fact" };
const SPEECH_PROMPTS: Record<string, string> = { polite: "use polite Korean honorifics when responding in Korean", casual: "use casual Korean speech when responding in Korean" };
const DETAIL_PROMPTS: Record<string, string> = { concise: "keep answers brief and focused", balanced: "use a balanced amount of detail", detailed: "provide thorough explanations with useful context" };

export class ContextBuilder {
  build(input: {
    profile: ProfileMemory[];
    longTerm: LongTermMemory[];
    conversation: ConversationMessage[];
    currentMessage: string;
  }): LlmRequest {
    const sections = [BASE_SYSTEM_PROMPT];
    const profile = input.profile.filter((item) => !RESPONSE_SETTING_KEYS.has(item.key));
    if (profile.length) {
      sections.push(`Profile memory:\n${profile.map((item) => `- ${item.key}: ${item.value}`).join("\n")}`);
    }
    const setting = (key: string) => input.profile.find((item) => item.key === key)?.value;
    const tone = setting("assistant_tone") ?? "friendly";
    const speech = setting("assistant_speech_style") ?? "polite";
    const detail = setting("assistant_response_detail") ?? "balanced";
    const custom = setting("assistant_custom_instructions")?.trim();
    sections.push(["Owner-configured response preferences:", `- Tone: ${TONE_PROMPTS[tone] ?? TONE_PROMPTS.friendly}`, `- Speech style: ${SPEECH_PROMPTS[speech] ?? SPEECH_PROMPTS.polite}`, `- Answer detail: ${DETAIL_PROMPTS[detail] ?? DETAIL_PROMPTS.balanced}`, ...(custom ? [`- Additional response instructions: ${custom}`] : []), "Apply these preferences unless they conflict with safety, accuracy, tool policy, or the user's current request."].join("\n"));
    if (input.longTerm.length) {
      sections.push(`Long-term memory:\n${input.longTerm.map((item) => `- [${item.category}] ${item.content}`).join("\n")}`);
    }
    const messages: LlmMessage[] = input.conversation
      .filter((message) => message.role === "user" || message.role === "assistant")
      .map((message) => ({ role: message.role as "user" | "assistant", content: message.content }));
    messages.push({ role: "user", content: input.currentMessage });
    return { systemPrompt: sections.join("\n\n"), messages };
  }
}
