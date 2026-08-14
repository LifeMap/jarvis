const SENSITIVE_KEY = /secret|token|api.?key|authorization|cookie|credential|password|client.?secret|auth.?url/i;
const SENSITIVE_TEXT = [
  /Bearer\s+[A-Za-z0-9._~+/=-]+/gi,
  /([?&](?:key|api_key|access_token|refresh_token|client_secret)=)[^&\s]+/gi,
  /\b(?:sk|AIza)[-_A-Za-z0-9]{12,}\b/g,
  /("?(?:access_token|refresh_token|client_secret|api_key|authorization)"?\s*[:=]\s*"?)[^",}\s]+/gi,
];

export function redactText(value: string): string {
  return SENSITIVE_TEXT.reduce((text, pattern) => text.replace(pattern, (_match, prefix?: string) => prefix ? `${prefix}[REDACTED]` : "[REDACTED]"), value);
}

export function redactValue(value: unknown): unknown {
  if (typeof value === "string") return redactText(value);
  if (Array.isArray(value)) return value.map(redactValue);
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value as Record<string, unknown>).filter(([key]) => !SENSITIVE_KEY.test(key)).map(([key, item]) => [key, redactValue(item)]));
  return value;
}

export function safeErrorMessage(error: unknown, fallback = "외부 서비스 요청에 실패했습니다."): string {
  return redactText(error instanceof Error ? error.message : typeof error === "string" ? error : fallback).slice(0, 1000);
}
