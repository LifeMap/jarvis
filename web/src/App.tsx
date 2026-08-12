import { FormEvent, useEffect, useMemo, useState } from "react";
import { Conversation } from "./components/Conversation";
import { DebugPanel } from "./components/DebugPanel";
import { VoiceControls } from "./components/VoiceControls";
import { useSpeechRecognition } from "./hooks/useSpeechRecognition";
import { useTextToSpeech } from "./hooks/useTextToSpeech";
import { useLocationContext } from "./hooks/useLocationContext";
import { AgentApiError, getConversation, resolveApproval, sendAgentMessage } from "./services/agent";
import type { ConversationMessage, DebugSnapshot } from "./types/agent";
import "./styles.css";

export default function App() {
  const [session, setSession] = useState(() => {
    const existing = window.localStorage.getItem("jarvis-session-id");
    const id = existing ?? crypto.randomUUID();
    if (!existing) window.localStorage.setItem("jarvis-session-id", id);
    return { id, restore: Boolean(existing) };
  });
  const [input, setInput] = useState("");
  const [messages, setMessages] = useState<ConversationMessage[]>([]);
  const [debug, setDebug] = useState<DebugSnapshot | null>(null);
  const [isLoading, setIsLoading] = useState(false);
  const [resolvingApproval, setResolvingApproval] = useState(false);
  const speechRecognition = useSpeechRecognition(setInput);
  const textToSpeech = useTextToSpeech();
  const locationContext = useLocationContext();
  const latestAssistantMessage = useMemo(
    () => [...messages].reverse().find((message) => message.role === "assistant")?.content,
    [messages],
  );

  useEffect(() => {
    if (!session.restore) return;
    let active = true;
    void getConversation(session.id)
      .then((stored) => {
        if (!active) return;
        setMessages(stored
          .filter((message) => message.role === "user" || message.role === "assistant")
          .map((message) => ({ id: message.messageId, role: message.role as "user" | "assistant", content: message.content })));
      })
      .catch((error) => {
        if (!active) return;
        const apiError = error instanceof AgentApiError ? error : new AgentApiError("Conversation 복원에 실패했습니다.");
        setDebug({ error: { message: apiError.message, ...(apiError.detail ? { detail: apiError.detail } : {}) } });
      });
    return () => { active = false; };
  }, [session]);

  const startNewSession = () => {
    const id = crypto.randomUUID();
    window.localStorage.setItem("jarvis-session-id", id);
    setSession({ id, restore: false });
    setMessages([]);
    setDebug(null);
  };

  const handleApproval = async (action: "approve" | "reject") => {
    const approval = debug?.response?.approval;
    if (!approval || resolvingApproval) return;
    setResolvingApproval(true);
    try {
      const updated = await resolveApproval(approval.approvalId, action);
      setDebug((current) => current?.response
        ? { ...current, response: { ...current.response, approval: updated, approvalRequired: updated.status === "PENDING" } }
        : current);
    } catch (error) {
      const apiError = error instanceof AgentApiError ? error : new AgentApiError("Approval 처리 중 오류가 발생했습니다.");
      setDebug({ error: { message: apiError.message, ...(apiError.detail ? { detail: apiError.detail } : {}), ...(apiError.status ? { status: apiError.status } : {}) } });
    } finally { setResolvingApproval(false); }
  };

  const submit = async (event: FormEvent) => {
    event.preventDefault();
    const message = input.trim();
    if (!message || isLoading) return;

    setMessages((current) => [...current, { id: crypto.randomUUID(), role: "user", content: message }]);
    setInput("");
    setDebug(null);
    setIsLoading(true);
    const startedAt = performance.now();

    try {
      const response = await sendAgentMessage(message, session.id, locationContext.location ? { location: locationContext.location } : undefined);
      setMessages((current) => [
        ...current,
        { id: crypto.randomUUID(), role: "assistant", content: formatAssistantMessage(response) },
      ]);
      setDebug({ response, roundTripTimeMs: Math.round(performance.now() - startedAt) });
    } catch (error) {
      const apiError = error instanceof AgentApiError ? error : new AgentApiError("알 수 없는 오류가 발생했습니다.");
      setDebug({
        error: {
          message: apiError.message,
          ...(apiError.detail ? { detail: apiError.detail } : {}),
          ...(apiError.status !== undefined ? { status: apiError.status } : {}),
        },
        roundTripTimeMs: Math.round(performance.now() - startedAt),
      });
    } finally {
      setIsLoading(false);
    }
  };

  return (
    <main className="app-shell">
      <header className="topbar">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true">J</span>
          <div>
            <strong>Jarvis</strong>
            <span>Agent Playground</span>
          </div>
        </div>
        <div className="session-controls">
          <code title={session.id}>Session {session.id.slice(0, 8)}</code>
          <button type="button" onClick={startNewSession}>새 Session</button>
          <div className="environment"><span /> Local development</div>
        </div>
      </header>

      <section className="hero">
        <p className="eyebrow">Personal assistant runtime</p>
        <h1>명령하고, 관찰하고,<br />Agent를 검증하세요.</h1>
        <p>Jarvis의 응답과 런타임 정보를 한 화면에서 확인하는 개발용 Playground입니다.</p>
      </section>

      <div className="workspace-grid">
        <Conversation messages={messages} isLoading={isLoading} />
        <DebugPanel debug={debug} onResolveApproval={handleApproval} resolvingApproval={resolvingApproval} />
      </div>

      <section className="composer-panel" aria-label="Agent command">
        <form onSubmit={submit}>
          <label htmlFor="agent-command">Agent command</label>
          <div className="composer-row">
            <textarea
              id="agent-command"
              value={input}
              onChange={(event) => setInput(event.target.value)}
              onKeyDown={(event) => {
                if (event.key === "Enter" && !event.shiftKey) {
                  event.preventDefault();
                  event.currentTarget.form?.requestSubmit();
                }
              }}
              placeholder="Jarvis에게 명령을 입력하세요…"
              rows={3}
              disabled={isLoading}
            />
            <button className="send-button" type="submit" disabled={!input.trim() || isLoading}>
              {isLoading ? "응답 대기 중" : "명령 보내기"}
              <span aria-hidden="true">↗</span>
            </button>
          </div>
        </form>

        <VoiceControls
          sttSupported={speechRecognition.isSupported}
          isListening={speechRecognition.isListening}
          sttError={speechRecognition.error}
          onStartListening={speechRecognition.start}
          onStopListening={speechRecognition.stop}
          ttsSupported={textToSpeech.isSupported}
          isSpeaking={textToSpeech.isSpeaking}
          canSpeak={Boolean(latestAssistantMessage)}
          onSpeak={() => latestAssistantMessage && textToSpeech.speak(latestAssistantMessage)}
          onStopSpeaking={textToSpeech.stop}
          locationStatus={locationContext.status}
          {...(locationContext.location?.accuracyMeters!==undefined?{locationAccuracy:locationContext.location.accuracyMeters}:{})}
          onRefreshLocation={locationContext.refresh}
        />
      </section>
    </main>
  );
}

function formatAssistantMessage(response:import("./types/agent").AgentMessageResponse){
  const location=response.context?.location;
  if(!location)return response.message;
  const accuracy=location.accuracyMeters!==undefined?` · 정확도 약 ${Math.round(location.accuracyMeters)}m`:"";
  return `${response.message}\n\n📍 현재 위치: ${location.latitude.toFixed(6)}, ${location.longitude.toFixed(6)}${accuracy}\n수집 시각: ${new Date(location.capturedAt).toLocaleString()}`;
}
