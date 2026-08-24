import type { CallDetail } from "../services/calls";

export function CallReportBanner({ report, onDismiss }: { report: CallDetail; onDismiss: () => void }) {
  const title = report.caller.name === "unknown" ? report.caller.phoneNumber : report.caller.name;
  return (
    <aside className="call-banner" role="status">
      <div>
        <strong>수신 전화</strong>
        <p>{title}</p>
        <p>{report.summary ?? "녹음을 확인하세요"}</p>
        {report.audioPath ? <audio controls src={report.audioPath} /> : null}
      </div>
      <button type="button" onClick={onDismiss}>닫기</button>
    </aside>
  );
}
