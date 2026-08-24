export interface CallCaller {
  name: string;
  phoneNumber: string;
}

export interface CallListItem {
  id: string;
  status: string;
  direction?: "incoming" | "outgoing";
  caller: CallCaller;
  startedAt: string;
  endedAt: string | null;
  summary: string | null;
  hasAudio: boolean;
  updatedAt: string;
}

export interface CallDetail extends CallListItem {
  transcript: Array<{ role: "caller" | "jarvis"; text: string }>;
  audioPath: string | null;
}

export async function listCalls(): Promise<CallListItem[]> {
  const response = await fetch("/api/calls", { headers: { accept: "application/json" } });
  if (!response.ok) return [];
  const payload = await response.json() as { calls?: CallListItem[] };
  return Array.isArray(payload.calls) ? payload.calls : [];
}

export async function getCall(id: string): Promise<CallDetail | null> {
  const response = await fetch(`/api/calls/${encodeURIComponent(id)}`, { headers: { accept: "application/json" } });
  if (!response.ok) return null;
  return await response.json() as CallDetail;
}
