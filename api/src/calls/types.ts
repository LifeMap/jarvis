export type CallStatus = "active" | "completed" | "upload_failed" | "failed";

const CALL_AUDIO_TIME_ZONE = "Asia/Seoul";

export function callAudioFolderStamp(startedAt: string) {
  const date = new Date(startedAt);
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: CALL_AUDIO_TIME_ZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date);
  const value = (type: Intl.DateTimeFormatPartTypes) =>
    parts.find((part) => part.type === type)?.value ?? "";
  return `${value("year")}${value("month")}${value("day")}${value("hour")}${value("minute")}${value("second")}`;
}

export type CallDirection = "incoming" | "outgoing";

export const FIXED_CALLBACK_SUMMARIES = ["콜백 연결 안 됨", "번호 없음"] as const;

export function normalizeFixedCallbackSummary(value: unknown): string | null {
  return value === "콜백 연결 안 됨" || value === "번호 없음" ? value : null;
}

export function folderPhoneNumber(value: string) {
  const compact = value.trim().replace(/[/\\]/g, "").replace(/\s+/g, "");
  if (!compact || compact === "unknown") return "unknown";
  if (compact.startsWith("+")) return compact.slice(0, 32);
  if (compact.startsWith("82") && compact.length >= 11) return `+${compact}`.slice(0, 32);
  if (compact.startsWith("0") && compact.length >= 8) return `+82${compact.slice(1)}`.slice(0, 32);
  return compact.slice(0, 32);
}

export function callAudioObjectKey(input: { startedAt: string; direction: CallDirection; phoneNumber: string }) {
  const kind = input.direction === "outgoing" ? "S" : "R";
  return `jarvis-call/${kind}_${callAudioFolderStamp(input.startedAt)}_${folderPhoneNumber(input.phoneNumber)}/merged.m4a`;
}

export interface CallCaller {
  name: string;
  phoneNumber: string;
}

export interface CallTranscriptTurn {
  role: "caller" | "jarvis";
  text: string;
}

export interface CallRecord {
  id: string;
  status: CallStatus;
  direction: CallDirection;
  caller: CallCaller;
  startedAt: string;
  endedAt: string | null;
  transcript: CallTranscriptTurn[];
  summary: string | null;
  audioKey: string | null;
  hasAudio: boolean;
  updatedAt: string;
}

export function callListItem(record: CallRecord) {
  return {
    id: record.id,
    status: record.status,
    direction: record.direction,
    caller: record.caller,
    startedAt: record.startedAt,
    endedAt: record.endedAt,
    summary: record.summary,
    hasAudio: record.hasAudio,
    updatedAt: record.updatedAt,
  };
}

export function callDetail(record: CallRecord) {
  return {
    ...callListItem(record),
    transcript: record.transcript,
    audioPath: record.hasAudio ? `/api/calls/${record.id}/audio` : null,
  };
}

export function normalizeDirection(value: unknown): CallDirection | null {
  if (value === undefined || value === null || value === "") return "incoming";
  if (value === "incoming" || value === "outgoing") return value;
  return null;
}

export function normalizeCaller(value: unknown): CallCaller | null {
  if (!value || typeof value !== "object") return null;
  const caller = value as Record<string, unknown>;
  const name = typeof caller.name === "string" ? caller.name.trim() : "";
  const phoneNumber = typeof caller.phoneNumber === "string" ? caller.phoneNumber.trim() : "";
  if (!name || !phoneNumber || name.length > 200 || phoneNumber.length > 64) return null;
  return { name, phoneNumber };
}

export function normalizeTranscript(value: unknown): CallTranscriptTurn[] | null {
  if (value === undefined) return [];
  if (!Array.isArray(value)) return null;
  const turns: CallTranscriptTurn[] = [];
  for (const item of value) {
    if (!item || typeof item !== "object") return null;
    const turn = item as Record<string, unknown>;
    if (turn.role !== "caller" && turn.role !== "jarvis") return null;
    if (typeof turn.text !== "string" || !turn.text.trim() || turn.text.length > 10_000) return null;
    turns.push({ role: turn.role, text: turn.text.trim() });
  }
  return turns;
}
