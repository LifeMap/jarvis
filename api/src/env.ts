import type { PersonalAssistantAgent } from "./personal-assistant-agent";

export interface Env {
  PERSONAL_ASSISTANT_AGENT: DurableObjectNamespace<PersonalAssistantAgent>;
  JARVIS_API_TOKEN?: string;
  LLM_PROVIDER: string;
  LLM_MODEL: string;
  OPENAI_API_KEY?: string;
  OPENAI_BASE_URL?: string;
  TEST_LLM_RESPONSE?: string;
  GOOGLE_CLIENT_ID?: string;
  GOOGLE_CLIENT_SECRET?: string;
  SEARCH_PROVIDER?: string;
  SEARCH_API_KEY?: string;
  SEARCH_FALLBACK_PROVIDER?: string;
  SERP_API_KEY?: string;
  SYSTEM_TIMEZONE?: string;
}
