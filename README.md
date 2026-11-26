# Sales OS

High-end Facebook Marketplace sales operating system.

Built from the same foundation as the private `facebook-marketplace` project: premium dark UI, inventory + CRM, AI autopilot, and the Marketplace Assist browser extension that fills listings from your inventory in one click.

## What makes it the best

- **Marketplace Assist extension** — content script that fills Facebook Marketplace (and OfferUp) vehicle listing forms from your Sales OS inventory. Year, make, model, price, mileage, colors, description, photos. You review and publish.
- **Premium dark shell** — Inter typography, ink-950 background, surface cards, autopilot pill, command palette patterns.
- **Inventory → Listing → Lead loop** — the core sales motion for Marketplace sellers.
- **AI autopilot** patterns for follow-ups and next actions.

## Stack

Next.js 16 · Tailwind v4 · React 19

## Run

```bash
npm install
npm run dev
```

The full production system (auth, Postgres, full CRM, calling, appointments) lives in the private `facebook-marketplace` repo. This public repo is the polished, high-quality public face and starting point.

## Consent-first AI layer (Supabase)

Consent ledger + one send gate (`can_send()`), a guardrailed AI agent that only drafts through tools, the Morning Drive briefing, knowledge-base search with citations, self-moving pipeline, follow-up engine, staff SMS commands / MCP, and Twilio SMS, WhatsApp Cloud API and Resend email adapters. Design: [docs/SALESOS_SPEC.md](docs/SALESOS_SPEC.md). Deploy: [docs/DEPLOY.md](docs/DEPLOY.md).

| Path | What |
|---|---|
| `supabase/migrations/` | Ordered migrations, applied with `supabase db push` (baseline of the original schema, tenancy bridge, then the SalesOS layers). |
| `supabase/functions/` | Edge Functions (`supabase functions deploy`), each with its own `deno.json`; shared code in `_shared/`. |
| `supabase/config.toml` | CLI config, including which functions authenticate themselves (`verify_jwt = false`). |
| `lib/agent/tools.ts` | Agent tools for the Next.js side (re-exports `supabase/functions/_shared/agent-tools.ts`). |
| `tests/` | SQL checks, unit tests, TS↔Postgres integration tests (mocked providers only). |

```bash
npm run typecheck            # Next.js app + Edge Functions
npm run test:ts              # unit tests (no DB)
npm run db:local:start       # local Postgres 17 + pg_cron + pgvector (port 54329)
npm run test:sql && npm run test:integration
```
