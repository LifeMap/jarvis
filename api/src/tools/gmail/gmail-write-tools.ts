import type { ToolContext, ToolDefinition } from "../types";
import { ToolError } from "../types";
import type { GmailMutationClient, GmailMutationResult, GmailSendRequest } from "./gmail-client";

abstract class GmailWriteTool implements ToolDefinition<GmailMutationResult> {
  abstract name: string;
  abstract description: string;
  abstract inputSchema: Record<string, unknown>;
  policy = "APPROVAL_REQUIRED" as const;
  requiresApproval = true as const;
  constructor(protected readonly client: GmailMutationClient) {}
  abstract parse(input: Record<string, unknown>): GmailSendRequest;
  async execute(input: Record<string, unknown>, _context: ToolContext) {
    try { return await this.client.send(this.parse(input)); }
    catch (error) {
      if (error instanceof ToolError) throw error;
      throw new ToolError("Gmail write failed", "Gmail 작업을 실행할 수 없습니다. Google 연결 상태를 확인해 주세요.", { cause: error });
    }
  }
  summarize(result: GmailMutationResult) { return `Gmail message sent: ${result.id}`; }
}

export class GmailSendTool extends GmailWriteTool {
  name = "gmail.send";
  description = "Send a new email. Requires explicit user approval.";
  inputSchema = gmailSchema(false);
  parse(input: Record<string, unknown>) { return parseMail(input, false); }
}

export class GmailReplyTool extends GmailWriteTool {
  name = "gmail.reply";
  description = "Reply in an existing Gmail thread. Requires explicit user approval.";
  inputSchema = gmailSchema(true);
  parse(input: Record<string, unknown>) { return parseMail(input, true); }
}

function gmailSchema(reply: boolean) {
  return {
    type: "object",
    properties: {
      to: { type: "string", description: "Recipient email address" },
      subject: { type: "string" }, body: { type: "string" },
      ...(reply ? { threadId: { type: "string" }, inReplyTo: { type: "string", description: "RFC Message-ID when available" } } : {}),
    },
    required: reply ? ["to", "subject", "body", "threadId"] : ["to", "subject", "body"],
  };
}
function parseMail(input: Record<string, unknown>, reply: boolean): GmailSendRequest {
  const to = requiredText(input.to, "to", 320);
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(to)) throw new ToolError("Invalid recipient", "수신자 이메일 주소가 올바르지 않습니다.");
  const value: GmailSendRequest = {
    to, subject: requiredText(input.subject, "subject", 998), body: requiredText(input.body, "body", 50_000),
  };
  if (reply) value.threadId = requiredText(input.threadId, "threadId", 256);
  if (typeof input.inReplyTo === "string" && input.inReplyTo.trim()) value.inReplyTo = input.inReplyTo.trim().slice(0, 998);
  return value;
}
function requiredText(value: unknown, name: string, max: number): string {
  if (typeof value !== "string" || !value.trim() || value.length > max) throw new ToolError(`Invalid ${name}`, `${name} 값이 올바르지 않습니다.`);
  return value.trim();
}
