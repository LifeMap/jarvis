# Jarvis API

Phase 1 Cloudflare Worker and `PersonalAssistantAgent` runtime.

Requires Node.js 22.18 or newer.

## Provider boundaries

`PersonalAssistantAgent` depends on two explicit provider boundaries:

```text
PersonalAssistantAgent
  +-- ModelProvider        workers-ai / openai (test in automated tests)
  +-- ToolProviderSet
      +-- gmail            gmail-api
      +-- calendar         google-calendar-api
      +-- search           brave-api (optional serpapi rate-limit fallback)
```

`llm/provider-factory.ts` owns Model Provider construction. `llm/model-registry.ts` lists the
explicitly supported models, and the active selection is stored in Durable Object SQLite rather
than in a Secret. `tools/provider-factory.ts` owns
external Tool Provider construction and environment interpretation. `ToolRegistry` receives those
providers and is limited to registering Tools and enforcing Tool execution policy. Provider IDs are
metadata separately from credentials. Service-specific active Tool Providers are resolved from
Durable Object SQLite; MCP transport and implementations are not implemented.

The default Model Provider is Workers AI using `@cf/qwen/qwen3-30b-a3b-fp8`. The previous
`@cf/meta/llama-3.3-70b-instruct-fp8-fast` model and OpenAI `gpt-5-mini` remain registered when
`OPENAI_API_KEY` is configured. Explicit chat commands can query, list, or change the active model;
the validated selection applies from the following request without a Worker deployment. No
automatic model fallback is performed.

## Local setup

```bash
npm install
cp .dev.vars.example .dev.vars
npx wrangler secret put JARVIS_API_TOKEN
npm run dev
```

For local development, put both `JARVIS_API_TOKEN` and `OPENAI_API_KEY` in the untracked
`.dev.vars` file. For deployment, register both values with `wrangler secret put`.

### Local secret reference

| Variable | Required | Meaning / source |
| --- | --- | --- |
| `JARVIS_API_TOKEN` | Yes | A long random token you choose. Web/Admin proxies must use the same value. |
| `OPENAI_API_KEY` | Real LLM only | OpenAI API dashboard key used for Agent responses. A ChatGPT subscription alone is not an API key. |
| `GOOGLE_CLIENT_ID` | Gmail/Calendar only | OAuth 2.0 Web application client ID from Google Cloud Console. |
| `GOOGLE_CLIENT_SECRET` | Gmail/Calendar only | Secret belonging to the Google OAuth client above. |
| `SEARCH_API_KEY` | Web Search only | Brave Search API subscription key. |
| `SERP_API_KEY` | Optional | SerpApi key used when `serpapi` is selected as active or configured fallback Provider. |

`DEFAULT_MODEL_PROVIDER`, `DEFAULT_MODEL`, `LLM_PROVIDER`, `LLM_MODEL`, `OPENAI_BASE_URL`,
`SEARCH_PROVIDER` and `SYSTEM_TIMEZONE` are
non-secret defaults declared in `wrangler.jsonc`; they normally do not need to be duplicated in
`.dev.vars`. Start with only `JARVIS_API_TOKEN` and `OPENAI_API_KEY`, then add Google and Search
credentials when testing those tools.

`wrangler.jsonc` binds Workers AI as `env.AI`. The immutable bootstrap default is explicitly set by
`DEFAULT_MODEL_PROVIDER` and `DEFAULT_MODEL`; production uses
`workers-ai / @cf/qwen/qwen3-30b-a3b-fp8`. A valid active model saved in Durable Object SQLite wins
over that default. With no saved row, Jarvis uses the default without silently selecting another
model. If the default is unregistered or its binding is unavailable, the request fails with a
configuration error. Qwen3 is always registered, while `WORKERS_AI_MODEL` keeps the previous Llama
3.3 model as an additional Workers AI choice and `OPENAI_MODEL` registers the OpenAI choice.
Provider/model choices are normal configuration; API keys remain Worker Secrets.

Model management examples:

```text
현재 모델 알려줘
사용 가능한 모델 알려줘
OpenAI 모델로 변경해
Workers AI 모델로 변경해
Workers AI의 @cf/qwen/qwen3-30b-a3b-fp8 모델로 변경해
Workers AI의 @cf/meta/llama-3.3-70b-instruct-fp8-fast 모델로 변경해
기본 모델이 뭐야?
기본 모델로 되돌려
```

Only explicit change/reset phrases invoke `model.set_active` or `model.reset_active`. A rejected
provider/model, missing binding/credential, or invalid default leaves the previous active
configuration unchanged. Reset persists the immutable default as the active selection and takes
effect on the next request without a code change or redeployment.

### Dynamic Tool Providers

| Service | Default Provider | Other registered Provider |
| --- | --- | --- |
| Gmail | `gmail-api` | None yet |
| Calendar | `google-calendar-api` | None yet |
| Search | `brave-api` | `serpapi` |

Active selections are stored in Durable Object SQLite table `tool_provider_configuration`. With no
stored selection, the explicit service default is used. Changes validate service registration,
Provider registration, credentials, OAuth connection, and availability before storage is updated.
Unimplemented MCP Provider IDs are rejected without changing the active Provider.

```text
현재 Gmail Provider 알려줘
현재 외부 서비스 Provider 상태를 전부 보여줘
Search Provider 목록 알려줘
Search Provider를 serpapi로 변경해
Search를 기본 Provider로 되돌려
```

Model and Tool Provider configurations use separate repositories and tables. `serpapi` can be
selected as the direct Search Provider or explicitly configured as the fallback for `brave-api`.
No Search fallback is created during bootstrap. When configured, timeout, network, HTTP 429, and
HTTP 5xx failures can invoke SerpApi once; authentication and validation failures never do.

Phase 4 external tools additionally require:

```text
GOOGLE_CLIENT_ID       Google OAuth Web application client ID
GOOGLE_CLIENT_SECRET   Google OAuth client secret
SEARCH_API_KEY         Brave Search API subscription token
```

Configure the Google OAuth Web application callback URI as:

```text
https://<your-worker-host>/api/oauth/google/callback
```

Enable Gmail API and Google Calendar API in the same Google Cloud project. Phase 5 requests
`gmail.readonly`, `gmail.send`, and `calendar.events`. The latter two are required for the
approval-gated Gmail and Calendar write tools. Begin the server-side OAuth flow
with authenticated `GET /api/oauth/google/authorize`, then open the returned URL. Connection
status is available from `GET /api/oauth/google/status`; `POST /api/oauth/google/disconnect`
removes the stored server-side token.

Tool execution summaries are available from authenticated `GET /api/tool-executions`.

## Approval API

Write tools never execute in the initial Agent request. Jarvis snapshots their validated-at-execution
arguments into Durable Object SQLite and returns a pending approval. The authenticated API is:

```text
GET  /api/approvals?status=PENDING
GET  /api/approvals/:id
POST /api/approvals/:id/approve
POST /api/approvals/:id/reject
```

Approval claims use a conditional SQLite transition from `PENDING` to `APPROVED`. Only the
request that claims that transition executes the saved arguments. Repeated requests and approvals
resolved as rejected, expired, executed, or failed return a conflict and never execute again.

```bash
curl http://localhost:8787/api/agent/message \
  -H 'Authorization: Bearer <JARVIS_API_TOKEN>' \
  -H 'Content-Type: application/json' \
  -d '{"message":"안녕 Jarvis"}'
```

## Verification

```bash
npm run check
npm test
npx wrangler deploy --dry-run
```

## Scheduler API

Jarvis uses the Agents SDK `schedule(Date, callback, payload)` API, which is persisted in the
Durable Object and backed by its native alarm. Application metadata and execution history remain
in the Jarvis `schedules` and `schedule_executions` SQLite tables.

```text
GET    /api/schedules
GET    /api/schedules/:id
POST   /api/schedules
PATCH  /api/schedules/:id
DELETE /api/schedules/:id
POST   /api/schedules/:id/run
GET    /api/schedule-executions?scheduleId=:id
```

One-time rules use `{ "runAt": "RFC3339" }`. Recurring rules use daily or weekly wall-clock
time, for example `{ "frequency":"weekly", "weekday":1, "hour":8, "minute":0 }`.
Jarvis calculates each next occurrence in the schedule timezone and registers it as a one-time
Agent schedule. This preserves Profile timezone and daylight-saving behavior rather than treating
a cron expression as implicitly UTC.
# MCP runtime configuration

The Worker exposes authenticated MCP management endpoints at `/api/mcp/servers`. Registration metadata is persisted in Durable Object SQLite. OAuth tokens and live connection state are managed by the Cloudflare Agents SDK. `credentialReference` must contain a binding name, never a credential value.

Supported operations: list/register/detail/remove, enable, disable, connection test, and dynamic Tool discovery. OAuth callbacks use the Agents SDK `/agents/{agent}/{instance}/callback` route.

## Unified runtime configuration

- `GET /api/runtime-configuration`: secret-free active/default Model, Tool Provider, and MCP connection snapshot
- `GET /api/runtime-configuration/history?limit=50`: recent configuration changes

`RuntimeConfigurationManager` orchestrates the existing Model, Tool Provider, and MCP services. Composite Model/Tool changes are validated as one plan and then persist selections plus history inside one Durable Object `transactionSync` transaction. Change history stores only sanitized selection metadata and never credentials or authorization headers.

## Provider health and fallback

Provider health is recorded as `healthy`, `degraded`, `unavailable`, or `unknown` with check time,
latency, and a safe reason. Runtime fallback is opt-in: no fallback row is created during bootstrap.
Model and service fallback selections are stored separately from active selections, so a fallback
execution never changes the active Provider.

Fallback is eligible only for transient Provider failures such as timeout, network failure, HTTP
429, and HTTP 5xx. Authentication, permission, invalid argument, and not-found failures are returned
without fallback. Read-only Tool calls may be attempted once through the configured fallback.
Approval-gated write Tool calls are never replayed through fallback because a timeout can occur after
the external service committed the mutation.

Authenticated inspection endpoints:

```text
GET /api/provider-health?target=search
GET /api/fallbacks
GET /api/fallback-events?limit=50
```

Natural-language examples:

```text
Provider 상태 확인해줘
OpenAI가 실패하면 Workers AI를 fallback으로 사용해
Search fallback으로 brave-api를 설정해
현재 fallback 설정 보여줘
최근 fallback 실행 내역 보여줘
Search fallback을 제거해
```

Configuration changes are recorded in `runtime_configuration_history`; actual failover attempts are
stored separately in `fallback_events`. Neither table stores credentials, OAuth tokens, request
authorization headers, or Tool payloads.

## Authentication and credential storage

Infrastructure Secrets remain Cloudflare Worker bindings and are never copied into SQLite:

| Reference | Purpose |
| --- | --- |
| `env:JARVIS_API_TOKEN` | Jarvis API authentication |
| `env:OPENAI_API_KEY` | OpenAI Provider |
| `env:SEARCH_API_KEY` | Brave Search Provider |
| `env:SERP_API_KEY` | Optional SerpApi Provider |
| `env:GOOGLE_CLIENT_ID` | Google OAuth client configuration |
| `env:GOOGLE_CLIENT_SECRET` | Google OAuth client secret |
| `binding:AI` | Workers AI binding |

Runtime OAuth credentials use `DurableObjectCredentialStore`. Secret material is isolated in
`runtime_credentials`; normal Runtime Configuration, MCP Registry, status APIs, and history contain
only a `credentialRef`, lifecycle status, scopes, and expiration metadata. Existing Google tokens in
`google_oauth_tokens` migrate to `google-oauth-main` on first read and the legacy row is deleted.

Authentication lifecycle values include `authorization-required`, `valid`, `expiring`, `expired`,
`refresh-failed`, and `revoked`. Google access tokens refresh once when needed; a refresh failure is
recorded as metadata and requires reconnection rather than an unbounded retry.

```text
GET /api/auth/status
GET /api/auth/status?target=gmail
```

Natural-language examples:

```text
현재 인증 상태 알려줘
Gmail 인증 상태 확인해
인증이 필요한 서비스 보여줘
Gmail 연결해
Gmail 연결 해제해
```

`Gmail 연결해` returns the existing `/api/oauth/google/authorize` entry point; Google consent still
requires the user’s browser interaction. MCP OAuth credentials and connection lifecycle remain under
the Cloudflare Agents SDK, while Registry metadata stores only references. No chat command can create
or rotate Cloudflare Worker Secrets.
