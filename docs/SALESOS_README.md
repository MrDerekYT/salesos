# SalesOS spec + reference implementation

Consent-first AI sales OS for car dealers on Next.js + Supabase. Design and decisions: [SPEC.md](SPEC.md). Original code; ideas credited in SPEC §6 (DeskcommCRM, AgentSDR, AgenticCRM, wacrm, Atomic CRM, all MIT).

## Layout

| Path | What |
|---|---|
| `supabase/migrations/` | 4 migrations (consent/agent/briefing → RAG/follow-ups/classification/MCP → runtime → offline gaps: outbox retry, bounces, facts, template compliance, staff verification). Idempotent. |
| `supabase/functions/` | Edge Functions. Each is a pure `handler.ts`/`process.ts` plus thin Deno `index.ts`; Postgres only via RPC. |
| `supabase/functions/_shared/channels/` | Twilio, WhatsApp Cloud, Resend and mock adapters, registry, dispatcher. |
| `lib/` | Shared TS (agent tools, before-send gates, opt-out detection, briefing, classifier). |
| `tests/sql`, `tests/ts`, `tests/integration` | SQL checks, unit tests, TS↔Postgres end-to-end (mocked HTTP only). |
| `scripts/` | Local Postgres (pg_cron + pgvector) and migration runner. |

## Run the tests locally

Needs Node 22+, and Postgres 17 with `pg_cron` and `pgvector` for the SQL/integration suites.

```bash
npm install
bash scripts/pg-local.sh start      # Postgres on port 54329, socket /tmp, db salesos_test
npm test                            # typecheck + unit + SQL + integration
npm run test:concurrency            # two-session cap race
bash scripts/pg-local.sh stop
```

Individually: `npm run typecheck`, `npm run test:ts` (no DB needed), `npm run test:sql`, `npm run test:integration`.
No test uses real credentials or the network: providers are exercised through mocked `fetch`, models through `MockLanguageModelV4`.

## Deploy (outline)

1. Enable `pg_cron`, `pg_net`, `vector`; store the project URL and service key in Vault (see SPEC §12) and apply the migrations.
2. Merge `supabase/config.toml` (`verify_jwt = false` for `webhook-twilio`, `webhook-meta`, `webhook-resend`, `unsubscribe`, `mcp`; they authenticate themselves).
3. Set the env vars below as function secrets, deploy all functions in `supabase/functions/`.
4. Point provider webhooks at `<PUBLIC_FUNCTIONS_URL>/webhook-twilio` (status callbacks are sent automatically with `?kind=status`), `/webhook-meta`, `/webhook-resend`.
5. Insert `channel_numbers` rows with `provider` and non-secret `provider_config` (`messaging_service_sid`; `phone_number_id` + `waba_id`; `from`).
6. Run one staging smoke test per provider before go-live.

Phase 5 functions: `keyword-reply-worker` (called by cron `salesos-keyword-replies` every 15 s with the service key; keep `verify_jwt` on) and `staff-verification` (called by signed-in staff from the app; keep `verify_jwt` on; not in `config.toml`). There are 12 `salesos-*` cron jobs in total.

## Environment variables (names only; never commit values)

| Name | Used by |
|---|---|
| `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY` | all functions |
| `PUBLIC_FUNCTIONS_URL` | Twilio signature URL, status callback URL |
| `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN` | Twilio adapter + webhook |
| `META_ACCESS_TOKEN`, `META_APP_SECRET`, `META_VERIFY_TOKEN`, `META_API_VERSION` | WhatsApp adapter, webhook, template sync |
| `RESEND_API_KEY`, `RESEND_WEBHOOK_SECRET` | Resend adapter + webhook (the key also fetches inbound email bodies) |
| `UNSUBSCRIBE_BASE_URL` | email List-Unsubscribe links |
| `AI_GATEWAY_API_KEY`, `AGENT_MODEL`, `CLASSIFIER_MODEL` | agent runner, classify worker, briefing (unset model → hand off / record failure) |
| `EMBEDDINGS_API_KEY`, `EMBEDDINGS_BASE_URL`, `EMBEDDINGS_MODEL` | embed worker (unset → FTS-only search) |
| `PREQUAL_BASE_URL` | pre-qualification links from the agent |
| `SALESOS_ALLOW_MOCK_PROVIDER` | set `true` only in dev to allow `provider = 'mock'` numbers |
