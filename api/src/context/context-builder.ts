import type { ConversationMessage, LongTermMemory, ProfileMemory } from "../contracts";
import type { LlmMessage, LlmRequest } from "../llm/types";

const BASE_SYSTEM_PROMPT = [
  "You are Jarvis, a private personal AI assistant for one user.",
  "Respond clearly and concisely in the language used by the user.",
  "Do not claim to have used tools or data sources that were not provided.",
].join(" ");

export class ContextBuilder {
  build(input: {
    profile: ProfileMemory[];
    longTerm: LongTermMemory[];
    conversation: ConversationMessage[];
    currentMessage: string;
  }): LlmRequest {
    const sections = [BASE_SYSTEM_PROMPT];
    if (input.profile.length) {
      sections.push(`Profile memory:\n${input.profile.map((item) => `- ${item.key}: ${item.value}`).join("\n")}`);
    }
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
