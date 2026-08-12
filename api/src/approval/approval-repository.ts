import type { SqlExecutor } from "../storage/sql";

export type ApprovalStatus = "PENDING" | "APPROVED" | "REJECTED" | "EXECUTED" | "FAILED" | "EXPIRED";
export interface Approval {
  approvalId: string; conversationId: string; requestId: string; toolCallId: string;
  toolName: string; toolArguments: Record<string, unknown>; policy: "APPROVAL_REQUIRED";
  status: ApprovalStatus; requestedAt: string; expiresAt: string | null; resolvedAt: string | null;
  executedAt: string | null; resultSummary: string | null; error: string | null; executionId: string | null;
}

export class ApprovalRepository {
  constructor(private readonly database: SqlExecutor) {}

  create(input: Omit<Approval, "status" | "requestedAt" | "resolvedAt" | "executedAt" | "resultSummary" | "error" | "executionId">): Approval {
    const requestedAt = new Date().toISOString();
    this.database.sql`
      INSERT INTO approvals (approval_id, conversation_id, request_id, tool_call_id, tool_name,
        tool_arguments_json, policy, status, requested_at, expires_at)
      VALUES (${input.approvalId}, ${input.conversationId}, ${input.requestId}, ${input.toolCallId},
        ${input.toolName}, ${JSON.stringify(input.toolArguments)}, ${input.policy}, 'PENDING',
        ${requestedAt}, ${input.expiresAt})
    `;
    return this.get(input.approvalId)!;
  }

  get(id: string): Approval | null {
    const [row] = this.database.sql<ApprovalRow>`SELECT * FROM approvals WHERE approval_id = ${id}`;
    return row ? mapApproval(row) : null;
  }

  list(status?: ApprovalStatus): Approval[] {
    const rows = status
      ? this.database.sql<ApprovalRow>`SELECT * FROM approvals WHERE status = ${status} ORDER BY requested_at DESC LIMIT 100`
      : this.database.sql<ApprovalRow>`SELECT * FROM approvals ORDER BY requested_at DESC LIMIT 100`;
    return rows.map(mapApproval);
  }

  markExpired(id: string, now: string): boolean {
    return this.database.sql<{ approval_id: string }>`
      UPDATE approvals SET status = 'EXPIRED', resolved_at = ${now}
      WHERE approval_id = ${id} AND status = 'PENDING' AND expires_at IS NOT NULL AND expires_at <= ${now}
      RETURNING approval_id
    `.length === 1;
  }

  claim(id: string, now: string): Approval | null {
    const [row] = this.database.sql<ApprovalRow>`
      UPDATE approvals SET status = 'APPROVED', resolved_at = ${now}
      WHERE approval_id = ${id} AND status = 'PENDING'
        AND (expires_at IS NULL OR expires_at > ${now})
      RETURNING *
    `;
    return row ? mapApproval(row) : null;
  }

  reject(id: string, now: string): Approval | null {
    const [row] = this.database.sql<ApprovalRow>`
      UPDATE approvals SET status = 'REJECTED', resolved_at = ${now}
      WHERE approval_id = ${id} AND status = 'PENDING'
        AND (expires_at IS NULL OR expires_at > ${now})
      RETURNING *
    `;
    return row ? mapApproval(row) : null;
  }

  finish(id: string, success: boolean, executionId: string, summary: string, error?: string): Approval {
    const now = new Date().toISOString();
    const status = success ? "EXECUTED" : "FAILED";
    const errorMessage = error ?? null;
    const [row] = this.database.sql<ApprovalRow>`
      UPDATE approvals SET status = ${status}, executed_at = ${now}, execution_id = ${executionId},
        result_summary = ${summary}, error_message = ${errorMessage}
      WHERE approval_id = ${id} AND status = 'APPROVED' RETURNING *
    `;
    if (!row) throw new Error("Approval execution state transition failed");
    return mapApproval(row);
  }
}

interface ApprovalRow {
  approval_id: string; conversation_id: string; request_id: string; tool_call_id: string;
  tool_name: string; tool_arguments_json: string; policy: "APPROVAL_REQUIRED"; status: ApprovalStatus;
  requested_at: string; expires_at: string | null; resolved_at: string | null; executed_at: string | null;
  result_summary: string | null; error_message: string | null; execution_id: string | null;
}
function mapApproval(row: ApprovalRow): Approval {
  return {
    approvalId: row.approval_id, conversationId: row.conversation_id, requestId: row.request_id,
    toolCallId: row.tool_call_id, toolName: row.tool_name,
    toolArguments: JSON.parse(row.tool_arguments_json) as Record<string, unknown>, policy: row.policy,
    status: row.status, requestedAt: row.requested_at, expiresAt: row.expires_at,
    resolvedAt: row.resolved_at, executedAt: row.executed_at, resultSummary: row.result_summary,
    error: row.error_message, executionId: row.execution_id,
  };
}
