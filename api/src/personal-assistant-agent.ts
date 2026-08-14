import { Agent, type AgentContext } from "agents";
import { ApprovalRepository, type Approval, type ApprovalStatus } from "./approval/approval-repository";
import type {
  AgentMessageResponse,
  AgentStateSnapshot,
  CreateMemoryInput,
  UpdateMemoryInput,
} from "./contracts";
import { ContextBuilder } from "./context/context-builder";
import { ConversationRepository } from "./conversation/conversation-repository";
import type { Env } from "./env";
import { createModelProvider } from "./llm/provider-factory";
import { ModelConfigurationRepository } from "./llm/model-configuration-repository";
import { ModelConfigurationService } from "./llm/model-configuration-service";
import { createModelRegistry } from "./llm/model-registry";
import { createModelManagementTools, parseModelManagementIntent } from "./llm/model-management-tools";
import { MemoryRepository } from "./memory/memory-repository";
import { GoogleOAuthRepository } from "./oauth/google-oauth-repository";
import { GoogleOAuthService } from "./oauth/google-oauth-service";
import { ensureApplicationSchema } from "./storage/schema";
import { ScheduleRepository } from "./scheduler/schedule-repository";
import { SchedulerService } from "./scheduler/scheduler-service";
import type { CreateScheduleInput, UpdateScheduleInput } from "./scheduler/types";
import { ToolExecutionRepository } from "./tools/tool-execution-repository";
import { createToolProviders } from "./tools/provider-factory";
import { ToolRegistry } from "./tools/tool-registry";
import { ToolProviderConfigurationRepository } from "./tools/tool-provider-configuration-repository";
import { ToolProviderConfigurationService } from "./tools/tool-provider-configuration-service";
import { createToolProviderManagementTools, parseToolProviderManagementIntent } from "./tools/tool-provider-management-tools";
import { createToolProviderRegistry } from "./tools/tool-provider-registry";
import { ToolProviderResolver } from "./tools/tool-provider-resolver";
import type { ToolCallDebug, ToolResultDebug } from "./tools/types";
import { ToolError, ToolPolicyError } from "./tools/types";

interface RunRow {
  id: string;
  request: string;
  response: string | null;
  model: string | null;
  status: "pending" | "completed" | "failed";
  error_message: string | null;
  execution_time_ms: number | null;
  created_at: string;
  completed_at: string | null;
}

export class PersonalAssistantAgent extends Agent<Env> {
  constructor(ctx: AgentContext, env: Env) {
    super(ctx, env);
    ensureApplicationSchema(this);
  }

  async message(message: string, sessionId = "default", location?: import("./contracts").RequestLocation): Promise<AgentMessageResponse> {
    const requestId = crypto.randomUUID();
    const createdAt = new Date().toISOString();
    const startedAt = Date.now();

    this.sql`
      INSERT INTO agent_runs (id, request, status, created_at)
      VALUES (${requestId}, ${message}, 'pending', ${createdAt})
    `;

    try {
      const conversations = new ConversationRepository(this);
      const memories = new MemoryRepository(this);
      const recentConversation = conversations.recentContext(sessionId, 20);
      const profile = memories.listProfile();
      const longTerm = memories.listLongTerm(100);
      conversations.addMessage({ sessionId, role: "user", content: message });

      const explicitMemory = parseExplicitMemory(message);
      const modelConfiguration = new ModelConfigurationService(new ModelConfigurationRepository(this), createModelRegistry(this.env));
      const modelIntent = explicitMemory ? null : parseModelManagementIntent(message, modelConfiguration);
      const oauth = new GoogleOAuthService(new GoogleOAuthRepository(this), this.env);
      const toolProviderConfiguration = this.toolProviderConfiguration(oauth);
      const toolProviderIntent = explicitMemory || modelIntent ? null : parseToolProviderManagementIntent(message);
      let savedMemoryId: string | undefined;
      let responseText = "";
      let responseModel = "";
      let toolCalls: ToolCallDebug[] = [];
      let toolResults: ToolResultDebug[] = [];
      let approval: Approval | undefined;
      let createdSchedule: import("./scheduler/types").JarvisSchedule | undefined;
      if (modelIntent) {
        const tool = createModelManagementTools(modelConfiguration).find((candidate) => candidate.name === modelIntent.toolName)!;
        const toolCallId = crypto.randomUUID();
        const toolStartedAt = Date.now();
        toolCalls = [{ id: toolCallId, name: tool.name, input: modelIntent.arguments, requiresApproval: false }];
        try {
          const result = await tool.execute(modelIntent.arguments, { timezone: this.env.SYSTEM_TIMEZONE ?? "UTC" });
          const summary = tool.summarize(result);
          const durationMs = Date.now() - toolStartedAt;
          responseText = summary; responseModel = "jarvis-model-management";
          toolResults = [{ toolCallId, name: tool.name, success: true, durationMs, summary }];
          new ToolExecutionRepository(this).record({ id: crypto.randomUUID(), requestId, toolName: tool.name, toolInput: modelIntent.arguments, success: true, durationMs, resultSummary: summary });
        } catch (error) {
          const summary = error instanceof ToolError ? error.userMessage : "모델 관리 작업에 실패했습니다. 기존 모델 설정은 유지됩니다.";
          const durationMs = Date.now() - toolStartedAt;
          responseText = summary; responseModel = "jarvis-model-management";
          toolResults = [{ toolCallId, name: tool.name, success: false, durationMs, summary, error: summary }];
          new ToolExecutionRepository(this).record({ id: crypto.randomUUID(), requestId, toolName: tool.name, toolInput: modelIntent.arguments, success: false, durationMs, resultSummary: summary, error: summary });
        }
      } else if (toolProviderIntent) {
        const tool = createToolProviderManagementTools(toolProviderConfiguration).find((candidate) => candidate.name === toolProviderIntent.toolName)!;
        const toolCallId = crypto.randomUUID();
        const toolStartedAt = Date.now();
        toolCalls = [{ id: toolCallId, name: tool.name, input: toolProviderIntent.arguments, requiresApproval: false }];
        try {
          const result = await tool.execute(toolProviderIntent.arguments, { timezone: this.env.SYSTEM_TIMEZONE ?? "UTC" });
          const summary = tool.summarize(result as never);
          const durationMs = Date.now() - toolStartedAt;
          responseText = summary; responseModel = "jarvis-tool-provider-management";
          toolResults = [{ toolCallId, name: tool.name, success: true, durationMs, summary }];
          new ToolExecutionRepository(this).record({ id: crypto.randomUUID(), requestId, toolName: tool.name, toolInput: toolProviderIntent.arguments, success: true, durationMs, resultSummary: summary });
        } catch (error) {
          const summary = error instanceof ToolError ? error.userMessage : "Tool Provider 관리 작업에 실패했습니다. 기존 설정은 유지됩니다.";
          const durationMs = Date.now() - toolStartedAt;
          responseText = summary; responseModel = "jarvis-tool-provider-management";
          toolResults = [{ toolCallId, name: tool.name, success: false, durationMs, summary, error: summary }];
          new ToolExecutionRepository(this).record({ id: crypto.randomUUID(), requestId, toolName: tool.name, toolInput: toolProviderIntent.arguments, success: false, durationMs, resultSummary: summary, error: summary });
        }
      } else if (explicitMemory) {
        const saved = memories.create({
          type: "long_term",
          content: explicitMemory,
          category: "preference",
          source: "user",
        });
        savedMemoryId = saved.id;
        responseText = "기억했습니다.";
        responseModel = "jarvis-memory";
      } else {
        const request = new ContextBuilder().build({
          profile,
          longTerm,
          conversation: recentConversation,
          currentMessage: message,
        });
        const timezone = resolveTimezone(
          profile.find((item) => item.key === "timezone")?.value,
          this.env.SYSTEM_TIMEZONE,
        );
        request.systemPrompt += `\n\nCurrent date/time: ${formatLocalDateTime(new Date(), timezone)} (${timezone}). Use this when interpreting relative dates and times.`;
        if(location)request.systemPrompt+=`\n\nCurrent request location (user-authorized, transient): latitude ${location.latitude}, longitude ${location.longitude}${location.accuracyMeters!==undefined?`, accuracy approximately ${location.accuracyMeters} meters`:""}, captured at ${location.capturedAt}. Use it only when relevant to this request. Do not claim a street address unless a tool provides one.`;
        const activeModel = modelConfiguration.getActive();
        if (!activeModel.enabled) throw new Error(activeModel.unavailableReason ?? "활성 Model Provider를 사용할 수 없습니다.");
        const provider = createModelProvider(this.env, activeModel);
        const scheduleRepository = new ScheduleRepository(this);
        const scheduler = new SchedulerService(scheduleRepository, this, timezone);
        const activeToolProviders = new ToolProviderResolver(toolProviderConfiguration).resolveAll();
        const registry = new ToolRegistry(createToolProviders(this.env, oauth, activeToolProviders), scheduler);
        const candidate = await provider.selectTool(request, registry.definitions());
        const selected = candidate && isExplicitMutationIntent(message, candidate.name) ? candidate
          : candidate && registry.get(candidate.name)?.policy === "APPROVAL_REQUIRED" ? null : candidate;
        if (selected) {
          const tool = registry.get(selected.name);
          if (tool) {
            if (tool.policy === "APPROVAL_REQUIRED") {
              approval = new ApprovalRepository(this).create({
                approvalId: crypto.randomUUID(), conversationId: sessionId, requestId,
                toolCallId: selected.id, toolName: selected.name, toolArguments: selected.arguments,
                policy: "APPROVAL_REQUIRED", expiresAt: new Date(Date.now() + 24 * 60 * 60_000).toISOString(),
              });
            }
            const debugCall: ToolCallDebug = {
              id: selected.id, name: selected.name, input: selected.arguments,
              requiresApproval: tool.requiresApproval, ...(approval ? { approvalId: approval.approvalId } : {}),
            };
            toolCalls = [debugCall];
            if (approval) {
              responseText = `승인이 필요한 작업입니다: ${selected.name}. 저장된 작업 내용을 확인한 뒤 승인하거나 거부해 주세요.`;
              responseModel = "jarvis-approval";
            } else {
            const started = Date.now();
            let toolPayload: unknown;
            let success = false;
            let error: string | undefined;
            let summary: string;
            try {
              toolPayload = (await registry.execute(selected.name, selected.arguments, { timezone })).result;
              if (selected.name === "scheduler.create") createdSchedule = toolPayload as import("./scheduler/types").JarvisSchedule;
              success = true;
              summary = tool.summarize(toolPayload);
            } catch (toolError) {
              error = toolError instanceof ToolError ? toolError.userMessage : "Tool 실행 중 오류가 발생했습니다.";
              toolPayload = { error };
              summary = error;
            }
            const durationMs = Date.now() - started;
            const debugResult: ToolResultDebug = {
              toolCallId: selected.id, name: selected.name, success, durationMs, summary,
              ...(error ? { error } : {}),
            };
            toolResults = [debugResult];
            new ToolExecutionRepository(this).record({
              id: crypto.randomUUID(), requestId, toolName: selected.name,
              toolInput: selected.arguments, success, durationMs, resultSummary: summary,
              ...(error ? { error } : {}),
            });
            const llmResponse = await provider.generateWithToolResult(request, selected, {
              success,
              data: toolPayload,
              instruction: success
                ? "Summarize the tool result naturally for the user."
                : "Clearly explain the failure without inventing data.",
            });
            responseText = llmResponse.text;
            responseModel = llmResponse.model;
            }
          }
        }
        if (!responseText) {
          const llmResponse = await provider.generate(request);
          responseText = llmResponse.text;
          responseModel = llmResponse.model;
        }
      }
      const executionTimeMs = Date.now() - startedAt;
      const completedAt = new Date().toISOString();
      conversations.addMessage({
        sessionId,
        role: "assistant",
        content: responseText,
        model: responseModel,
        ...(toolCalls.length ? { toolCalls } : {}),
        ...(toolResults.length ? { toolResult: toolResults } : {}),
      });

      this.sql`
        UPDATE agent_runs
        SET response = ${responseText}, model = ${responseModel},
            status = 'completed', execution_time_ms = ${executionTimeMs}, completed_at = ${completedAt}
        WHERE id = ${requestId}
      `;

      return {
        message: responseText,
        toolCalls,
        toolResults,
        approvalRequired: Boolean(approval),
        ...(approval ? { approval } : {}),
        ...(createdSchedule ? { schedule: createdSchedule } : {}),
        model: responseModel,
        executionTimeMs,
        requestId,
        sessionId,
        ...(location?{context:{location}}:{}),
        memory: {
          ...(savedMemoryId ? { savedMemoryId } : {}),
          profileCount: memories.listProfile().length,
          longTermMemoryCount: memories.listLongTerm(100).length,
          conversationMessageCount: conversations.listMessages(sessionId).length,
        },
      };
    } catch (error) {
      const executionTimeMs = Date.now() - startedAt;
      const completedAt = new Date().toISOString();
      const errorMessage = error instanceof Error ? error.message : "알 수 없는 오류";

      this.sql`
        UPDATE agent_runs
        SET status = 'failed', error_message = ${errorMessage},
            execution_time_ms = ${executionTimeMs}, completed_at = ${completedAt}
        WHERE id = ${requestId}
      `;
      throw error;
    }
  }

  stateSnapshot(): AgentStateSnapshot {
    const [row] = this.sql<{ request_count: number; last_request_at: string | null }>`
      SELECT COUNT(*) AS request_count, MAX(created_at) AS last_request_at
      FROM agent_runs
    `;

    return {
      requestCount: row?.request_count ?? 0,
      lastRequestAt: row?.last_request_at ?? null,
      sqliteConnected: true,
    };
  }

  latestRun(): RunRow | null {
    const [run] = this.sql<RunRow>`
      SELECT id, request, response, model, status, error_message,
             execution_time_ms, created_at, completed_at
      FROM agent_runs
      ORDER BY created_at DESC
      LIMIT 1
    `;
    return run ?? null;
  }

  listAgentRuns(limit=100){return this.sql<RunRow>`SELECT id,request,response,model,status,error_message,execution_time_ms,created_at,completed_at FROM agent_runs ORDER BY created_at DESC LIMIT ${limit}`.map(mapRun)}
  getAgentRun(id:string){const [run]=this.sql<RunRow>`SELECT id,request,response,model,status,error_message,execution_time_ms,created_at,completed_at FROM agent_runs WHERE id=${id}`;return run?{...mapRun(run),toolExecutions:new ToolExecutionRepository(this).listByRequestId(id),tokenUsage:null}:null}

  adminToolStatus(){
    const oauthService=new GoogleOAuthService(new GoogleOAuthRepository(this),this.env);const oauth=oauthService.status();
    const latest=new ToolExecutionRepository(this).list(100);
    const registry=new ToolRegistry(createToolProviders(this.env,oauthService,new ToolProviderResolver(this.toolProviderConfiguration(oauthService)).resolveAll()),new SchedulerService(new ScheduleRepository(this),this,this.env.SYSTEM_TIMEZONE??"UTC"));
    return registry.tools.map(tool=>({name:tool.name,description:tool.description,enabled:true,policy:tool.policy,requiresApproval:tool.requiresApproval,
      connection:tool.name.startsWith("gmail.")||tool.name.startsWith("calendar.")||tool.name.startsWith("google_calendar.")?(oauth.connected?"connected":"disconnected"):registry.provider(tool.name)?.implementation!=="unavailable"?"available":"unavailable",
      provider:registry.provider(tool.name),
      permission:tool.policy==="APPROVAL_REQUIRED"?"Write with approval":"Read / safe",latestExecution:latest.find(item=>item.toolName===tool.name)??null}));
  }

  adminSettings(){const profile=new MemoryRepository(this).listProfile();const value=(key:string,fallback:string)=>profile.find(x=>x.key===key)?.value??fallback;const active=new ModelConfigurationService(new ModelConfigurationRepository(this),createModelRegistry(this.env)).getActive();return{language:value("language","ko"),timezone:resolveTimezone(value("timezone",this.env.SYSTEM_TIMEZONE??"UTC"),this.env.SYSTEM_TIMEZONE),responseTone:value("assistant_tone","friendly"),speechStyle:value("assistant_speech_style","polite"),responseDetail:value("assistant_response_detail","balanced"),customInstructions:value("assistant_custom_instructions",""),llmProvider:active.provider,llmModel:active.model,systemTimezone:this.env.SYSTEM_TIMEZONE??"UTC",secretsManagedBy:"Cloudflare Secrets"}}
  updateAdminSettings(input:{language?:string;timezone?:string;responseTone?:string;speechStyle?:string;responseDetail?:string;customInstructions?:string}){const repo=new MemoryRepository(this);if(input.language)repo.create({type:"profile",key:"language",value:limitedText(input.language,"language",32),source:"user"});if(input.timezone){const timezone=resolveTimezone(input.timezone);if(timezone!==input.timezone)throw new Error("Invalid timezone");repo.create({type:"profile",key:"timezone",value:timezone,source:"user"})}if(input.responseTone!==undefined)repo.create({type:"profile",key:"assistant_tone",value:enumValue(input.responseTone,["friendly","professional","warm","direct"],"responseTone"),source:"user"});if(input.speechStyle!==undefined)repo.create({type:"profile",key:"assistant_speech_style",value:enumValue(input.speechStyle,["polite","casual"],"speechStyle"),source:"user"});if(input.responseDetail!==undefined)repo.create({type:"profile",key:"assistant_response_detail",value:enumValue(input.responseDetail,["concise","balanced","detailed"],"responseDetail"),source:"user"});if(input.customInstructions!==undefined)repo.create({type:"profile",key:"assistant_custom_instructions",value:limitedText(input.customInstructions,"customInstructions",4000,true),source:"user"});return this.adminSettings()}

  adminDashboard(){const runs=this.listAgentRuns(10);const tools=new ToolExecutionRepository(this).list(10);const approvals=new ApprovalRepository(this).list();const schedules=new ScheduleRepository(this).list();const scheduleExecutions=new ScheduleRepository(this).executions();const scheduleTitles=new Map(schedules.map(schedule=>[schedule.id,schedule.title]));return{counts:{pendingApprovals:approvals.filter(x=>x.status==="PENDING").length,activeSchedules:schedules.filter(x=>x.enabled&&(x.status==="scheduled"||x.status==="running"||x.status==="failed")).length,recentErrors:runs.filter(x=>x.status==="failed").length+tools.filter(x=>!x.success).length+(scheduleExecutions as Array<{success?:number}>).filter(x=>x.success===0).length},recentRuns:runs,recentTools:tools,recentScheduleExecutions:scheduleExecutions.slice(0,10).map(execution=>({...execution,scheduleTitle:scheduleTitles.get(String(execution.schedule_id))??null}))}}

  listConversations() {
    return new ConversationRepository(this).listSessions();
  }

  getConversation(sessionId: string) {
    return new ConversationRepository(this).listMessages(sessionId);
  }

  deleteConversation(sessionId: string): boolean {
    return new ConversationRepository(this).deleteSession(sessionId);
  }

  listMemories() {
    const repository = new MemoryRepository(this);
    return { profile: repository.listProfile(), longTerm: repository.listLongTerm() };
  }

  createMemory(input: CreateMemoryInput) {
    return new MemoryRepository(this).create(input);
  }

  updateMemory(id: string, input: UpdateMemoryInput) {
    return new MemoryRepository(this).update(id, input);
  }

  deleteMemory(id: string): boolean {
    return new MemoryRepository(this).delete(id);
  }

  googleAuthorizationUrl(redirectUri: string): string {
    return new GoogleOAuthService(new GoogleOAuthRepository(this), this.env).createAuthorizationUrl(redirectUri);
  }

  async completeGoogleAuthorization(code: string, state: string): Promise<void> {
    await new GoogleOAuthService(new GoogleOAuthRepository(this), this.env).completeAuthorization(code, state);
  }

  googleConnectionStatus() {
    return new GoogleOAuthService(new GoogleOAuthRepository(this), this.env).status();
  }

  disconnectGoogle(): boolean {
    return new GoogleOAuthService(new GoogleOAuthRepository(this), this.env).disconnect();
  }

  listToolExecutions() {
    return new ToolExecutionRepository(this).list();
  }

  listJarvisSchedules(){return new ScheduleRepository(this).list()}
  getJarvisSchedule(id:string){return new ScheduleRepository(this).get(id)}
  listScheduleExecutions(id?:string){return new ScheduleRepository(this).executions(id)}
  async createJarvisSchedule(input:CreateScheduleInput){const timezone=resolveTimezone(input.timezone??new MemoryRepository(this).listProfile().find(x=>x.key==="timezone")?.value,this.env.SYSTEM_TIMEZONE);return new SchedulerService(new ScheduleRepository(this),this,timezone).create({...input,timezone})}
  async updateJarvisSchedule(id:string,input:UpdateScheduleInput){const timezone=resolveTimezone(input.timezone??new MemoryRepository(this).listProfile().find(x=>x.key==="timezone")?.value,this.env.SYSTEM_TIMEZONE);return new SchedulerService(new ScheduleRepository(this),this,timezone).update(id,input)}
  async deleteJarvisSchedule(id:string){return new SchedulerService(new ScheduleRepository(this),this,this.env.SYSTEM_TIMEZONE??"UTC").delete(id)}
  async runJarvisSchedule(id:string){const schedule=new ScheduleRepository(this).get(id);if(!schedule)return{ok:false,code:"NOT_FOUND"};if(schedule.nativeScheduleId)await this.cancelSchedule(schedule.nativeScheduleId);return this.executeSchedule({scheduleId:id},"manual")}

  async executeScheduledTask(payload:{scheduleId:string}){return this.executeSchedule(payload,"scheduled")}

  private async executeSchedule(payload:{scheduleId:string},trigger:"manual"|"scheduled"){
    const repository=new ScheduleRepository(this);const schedule=repository.claim(payload.scheduleId);
    if(!schedule)return{ok:false,code:"NOT_RUNNABLE"};
    const executionId=crypto.randomUUID();repository.startExecution(executionId,schedule.id,trigger);
    try{
      const response=await this.message(schedule.instruction,`schedule:${schedule.id}`);
      const success=!response.toolResults.some(result=>!result.success);
      let next:string|null=null;let status:import("./scheduler/types").ScheduleStatus;
      if(schedule.scheduleType==="recurring"&&schedule.enabled){const at=await new SchedulerService(repository,this,schedule.timezone).rescheduleRecurring(schedule);next=at.toISOString();status=success?"scheduled":"failed"}else status=success?"completed":"failed";
      repository.finish(schedule.id,status,next,response.message);repository.finishExecution(executionId,success,response.message,success?null:"Scheduled Tool execution failed",response.toolCalls);
      return{ok:true,schedule:repository.get(schedule.id),response};
    }catch(error){const message=error instanceof Error?error.message:"Scheduled task failed";if(schedule.scheduleType==="recurring"&&schedule.enabled){try{const at=await new SchedulerService(repository,this,schedule.timezone).rescheduleRecurring(schedule);repository.finish(schedule.id,"failed",at.toISOString(),message)}catch{repository.finish(schedule.id,"failed",null,message)}}else repository.finish(schedule.id,"failed",null,message);repository.finishExecution(executionId,false,null,message,[]);return{ok:false,code:"EXECUTION_FAILED",error:message,schedule:repository.get(schedule.id)}}
  }

  listApprovals(status?: ApprovalStatus) { return new ApprovalRepository(this).list(status); }
  getApproval(id: string) { return new ApprovalRepository(this).get(id); }

  rejectApproval(id: string): ApprovalActionResult {
    const repository = new ApprovalRepository(this);
    const existing = repository.get(id);
    if (!existing) return { ok: false, code: "NOT_FOUND", message: "Approval을 찾을 수 없습니다." };
    const now = new Date().toISOString();
    if (existing.status === "PENDING" && existing.expiresAt && existing.expiresAt <= now) {
      repository.markExpired(id, now);
      return { ok: false, code: "EXPIRED", message: "Approval이 만료되었습니다.", approval: repository.get(id)! };
    }
    const approval = repository.reject(id, now);
    return approval
      ? { ok: true, approval }
      : { ok: false, code: "ALREADY_RESOLVED", message: "이미 처리된 Approval입니다.", approval: repository.get(id)! };
  }

  async approveApproval(id: string): Promise<ApprovalActionResult> {
    const repository = new ApprovalRepository(this);
    const existing = repository.get(id);
    if (!existing) return { ok: false, code: "NOT_FOUND", message: "Approval을 찾을 수 없습니다." };
    const now = new Date().toISOString();
    if (existing.status === "PENDING" && existing.expiresAt && existing.expiresAt <= now) {
      repository.markExpired(id, now);
      return { ok: false, code: "EXPIRED", message: "Approval이 만료되었습니다.", approval: repository.get(id)! };
    }
    const oauth = new GoogleOAuthService(new GoogleOAuthRepository(this), this.env);
    const registry = new ToolRegistry(createToolProviders(this.env, oauth, new ToolProviderResolver(this.toolProviderConfiguration(oauth)).resolveAll()));
    const tool = registry.get(existing.toolName);
    if (!tool) return { ok: false, code: "TOOL_NOT_FOUND", message: "요청된 Tool을 찾을 수 없습니다.", approval: existing };
    if (tool.policy !== "APPROVAL_REQUIRED") return { ok: false, code: "POLICY_MISMATCH", message: "Tool 승인 정책이 일치하지 않습니다.", approval: existing };
    const claimed = repository.claim(id, now);
    if (!claimed) return { ok: false, code: "ALREADY_RESOLVED", message: "이미 처리된 Approval입니다.", approval: repository.get(id)! };

    const profile = new MemoryRepository(this).listProfile();
    const timezone = resolveTimezone(profile.find((item) => item.key === "timezone")?.value, this.env.SYSTEM_TIMEZONE);
    const executionId = crypto.randomUUID();
    const started = Date.now();
    try {
      const { result } = await registry.execute(claimed.toolName, claimed.toolArguments, { timezone }, { approvalId: id, toolName: claimed.toolName });
      const summary = tool.summarize(result);
      const durationMs = Date.now() - started;
      new ToolExecutionRepository(this).record({ id: executionId, requestId: claimed.requestId, toolName: claimed.toolName, toolInput: claimed.toolArguments, success: true, durationMs, resultSummary: summary });
      return { ok: true, approval: repository.finish(id, true, executionId, summary), result: { summary, durationMs } };
    } catch (error) {
      const message = error instanceof ToolError ? error.userMessage
        : error instanceof ToolPolicyError ? error.message : "Tool 실행 중 오류가 발생했습니다.";
      const durationMs = Date.now() - started;
      new ToolExecutionRepository(this).record({ id: executionId, requestId: claimed.requestId, toolName: claimed.toolName, toolInput: claimed.toolArguments, success: false, durationMs, resultSummary: message, error: message });
      return { ok: true, approval: repository.finish(id, false, executionId, message, message), result: { summary: message, durationMs } };
    }
  }

  private toolProviderConfiguration(oauth: GoogleOAuthService): ToolProviderConfigurationService {
    return new ToolProviderConfigurationService(
      new ToolProviderConfigurationRepository(this),
      createToolProviderRegistry(this.env, { googleConnected: oauth.status().connected }),
    );
  }
}

export type ApprovalActionResult =
  | { ok: true; approval: Approval; result?: { summary: string; durationMs: number } }
  | { ok: false; code: "NOT_FOUND" | "ALREADY_RESOLVED" | "EXPIRED" | "TOOL_NOT_FOUND" | "POLICY_MISMATCH"; message: string; approval?: Approval };

function mapRun(row:RunRow){return{id:row.id,request:row.request,response:row.response,model:row.model,status:row.status,error:row.error_message,executionTimeMs:row.execution_time_ms,createdAt:row.created_at,completedAt:row.completed_at,triggerType:"manual" as const}}

function resolveTimezone(profileTimezone?: string, systemTimezone?: string): string {
  for (const candidate of [profileTimezone, systemTimezone, "UTC"]) {
    if (!candidate) continue;
    try {
      new Intl.DateTimeFormat("en", { timeZone: candidate }).format(new Date());
      return candidate;
    } catch {
      // Ignore invalid profile values and continue to the configured fallback.
    }
  }
  return "UTC";
}

function formatLocalDateTime(date: Date, timezone: string): string {
  return new Intl.DateTimeFormat("sv-SE", {
    timeZone: timezone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).format(date);
}

function parseExplicitMemory(message: string): string | null {
  const match = message.match(/^\s*기억해\s*줘[.!,:;\s-]*(.+)$/s)
    ?? message.match(/^\s*remember(?:\s+that)?[.!,:;\s-]+(.+)$/is);
  const content = match?.[1]?.trim();
  return content ? content : null;
}

function isExplicitMutationIntent(message: string, toolName: string): boolean {
  if (toolName === "gmail.send") return /(메일|gmail|email)/i.test(message) && /(보내|발송|전송|send)/i.test(message);
  if (toolName === "gmail.reply") return /(답장|회신|reply)/i.test(message);
  if (toolName === "calendar.create") return /(일정|캘린더|calendar|회의|미팅)/i.test(message) && /(만들|생성|추가|등록|create|add)/i.test(message);
  if (toolName === "calendar.update") return /(일정|캘린더|calendar|회의|미팅)/i.test(message) && /(수정|변경|옮겨|update|change)/i.test(message);
  if (toolName === "calendar.delete") return /(일정|캘린더|calendar|회의|미팅)/i.test(message) && /(삭제|취소|지워|delete|cancel)/i.test(message);
  return true;
}

function enumValue(value:string,allowed:string[],name:string):string{if(!allowed.includes(value))throw new Error(`Invalid ${name}`);return value}
function limitedText(value:string,name:string,max:number,allowEmpty=false):string{if(typeof value!=="string"||value.length>max||(!allowEmpty&&!value.trim()))throw new Error(`Invalid ${name}`);return value.trim()}
