import type { ConversationMessage } from "../types/agent";

interface ConversationProps {
  messages: ConversationMessage[];
  isLoading: boolean;
}

export function Conversation({ messages, isLoading }: ConversationProps) {
  return (
    <section className="panel conversation-panel" aria-labelledby="conversation-title">
      <div className="panel-heading">
        <div>
          <p className="eyebrow">Conversation</p>
          <h2 id="conversation-title">대화</h2>
        </div>
        <span className="message-count">{messages.length} messages</span>
      </div>

      <div className="message-list" aria-live="polite">
        {messages.length === 0 ? (
          <div className="empty-state">
            <span className="empty-orb" aria-hidden="true" />
            <p>Jarvis에게 첫 명령을 보내세요.</p>
            <small>예: 오늘 할 일을 간단히 정리해줘</small>
          </div>
        ) : (
          messages.map((message) => (
            <article className={`message message-${message.role}`} key={message.id}>
              <span className="message-role">{message.role === "user" ? "User" : "Jarvis"}</span>
              <p>{message.content}</p>
            </article>
          ))
        )}
        {isLoading && (
          <div className="typing" role="status">
            <span /><span /><span />
            <span className="sr-only">Jarvis가 응답을 생성하고 있습니다.</span>
          </div>
        )}
      </div>
    </section>
  );
}
