import type { DebugSnapshot } from "../types/agent";

export function DebugPanel({ debug, onResolveApproval, resolvingApproval = false }: {
  debug: DebugSnapshot | null;
  onResolveApproval?: (action: "approve" | "reject") => void;
  resolvingApproval?: boolean;
}) {
  const response = debug?.response;

  return (
    <aside className="panel debug-panel" aria-labelledby="debug-title">
      <div className="panel-heading">
        <div>
          <p className="eyebrow">Runtime</p>
          <h2 id="debug-title">Debug</h2>
        </div>
        <span className={`status-dot ${debug?.error ? "status-error" : response ? "status-ok" : ""}`}>
          {debug?.error ? "Error" : response ? "Complete" : "Idle"}
        </span>
      </div>

      {!debug ? (
        <p className="debug-placeholder">요청 후 Agent 실행 정보가 표시됩니다.</p>
      ) : debug.error ? (
        <div className="error-card" role="alert">
          <strong>{debug.error.message}</strong>
          {debug.error.detail && <p>{debug.error.detail}</p>}
          {debug.error.status && <code>HTTP {debug.error.status}</code>}
        </div>
      ) : response ? (
        <dl className="debug-grid">
          <DebugRow label="Model" value={response.model} />
          <DebugRow label="Agent duration" value={`${response.executionTimeMs} ms`} />
          {debug.roundTripTimeMs !== undefined && (
            <DebugRow label="Round trip" value={`${debug.roundTripTimeMs} ms`} />
          )}
          <DebugRow label="Approval" value={response.approvalRequired ? "Required" : "Not required"} />
          {response.approval && <ApprovalCard approval={response.approval} onResolve={onResolveApproval} disabled={resolvingApproval} />}
          <DebugRow label="Request ID" value={response.requestId} mono />
          <DebugRow label="Session ID" value={response.sessionId} mono />
          {response.memory && (
            <>
              <DebugRow label="Profile memory" value={`${response.memory.profileCount}`} />
              <DebugRow label="Long-term memory" value={`${response.memory.longTermMemoryCount}`} />
              <DebugRow label="Session messages" value={`${response.memory.conversationMessageCount}`} />
              {response.memory.savedMemoryId && <DebugRow label="Saved memory" value={response.memory.savedMemoryId} mono />}
            </>
          )}
          <ToolExecutions calls={response.toolCalls} results={response.toolResults ?? []} />
        </dl>
      ) : null}
    </aside>
  );
}

function ApprovalCard({ approval, onResolve, disabled }: {
  approval: import("../types/agent").Approval;
  onResolve: ((action: "approve" | "reject") => void) | undefined;
  disabled: boolean;
}) {
  return <div className="debug-row debug-json approval-card">
    <dt>Pending Approval</dt>
    <dd>
      <strong>{approval.toolName}</strong>
      <span className={`approval-status approval-${approval.status.toLowerCase()}`}>{approval.status}</span>
      <code>{approval.approvalId}</code>
      <pre>{JSON.stringify(approval.toolArguments, null, 2)}</pre>
      {approval.resultSummary && <p>{approval.resultSummary}</p>}
      {approval.error && <p className="tool-failure">{approval.error}</p>}
      {approval.status === "PENDING" && <div className="approval-actions">
        <button type="button" disabled={disabled} onClick={() => onResolve?.("approve")}>승인</button>
        <button type="button" disabled={disabled} onClick={() => onResolve?.("reject")}>거부</button>
      </div>}
    </dd>
  </div>;
}

function DebugRow({ label, value, mono = false }: { label: string; value: string; mono?: boolean }) {
  return (
    <div className="debug-row">
      <dt>{label}</dt>
      <dd className={mono ? "mono" : ""}>{value}</dd>
    </div>
  );
}

function ToolExecutions({ calls, results }: {
  calls: import("../types/agent").ToolCallDebug[];
  results: import("../types/agent").ToolResultDebug[];
}) {
  return (
    <div className="debug-row debug-json">
      <dt>Tool executions</dt>
      <dd>{calls.length === 0 ? "No tool calls" : calls.map((call) => {
        const result = results.find((item) => item.toolCallId === call.id);
        return (
          <div className="tool-debug-card" key={call.id}>
            <strong>{call.name}</strong>
            <span className={result?.success ? "tool-success" : "tool-failure"}>{result?.success ? "success" : "failure"}</span>
            <code>{result ? `${result.durationMs} ms` : "pending"}</code>
            <pre>{JSON.stringify(call.input, null, 2)}</pre>
            {result && <p>{result.summary}</p>}
          </div>
        );
      })}</dd>
    </div>
  );
}
