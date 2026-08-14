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
| `SERP_API_KEY` | Optional fallback | SerpApi key used only after Brave returns HTTP 429 twice. |

`DEFAULT_MODEL_PROVIDER`, `DEFAULT_MODEL`, `LLM_PROVIDER`, `LLM_MODEL`, `OPENAI_BASE_URL`,
`SEARCH_PROVIDER`, `SEARCH_FALLBACK_PROVIDER`, and `SYSTEM_TIMEZONE` are
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

Model and Tool Provider configurations use separate repositories and tables. Existing Brave 429 →
SerpApi fallback remains part of `brave-api`; selecting `serpapi` makes it the direct Search
Provider.

Web Search uses Brave first. On HTTP 429 it waits one second and retries Brave once; only a second
429 activates SerpApi. Authentication, validation, and server failures do not trigger paid-provider
fallback. If SerpApi also returns 429 because its free allowance is exhausted, Jarvis reports the
search failure and does not retry indefinitely.

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
