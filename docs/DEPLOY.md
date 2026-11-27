# Deploying SalesOS AI (live project `salesos`, ref `oevzihocfpejskkyosrq`)

## Where it lives
Everything new is in the Postgres schema **`salesos_ai`**. Nothing in `salesos`, `public` or `work` was dropped, renamed or rewritten, and `agentphone-webhook` was not changed.

| Live object | SalesOS AI | How they're linked |
|---|---|---|
| `salesos.accounts` (Ocean Cadillac, Anthony) | `salesos_ai.dealers` | `dealers.salesos_account_id` |
| `salesos.users` | `salesos_ai.dealer_members` | `dealer_members.salesos_user_id` (role owner/admin/manager/sales) |
| `salesos.customers` | `salesos_ai.contacts` + `salesos_ai.leads` | `salesos_customer_id`; phone normalized to E.164; `do_not_contact=1` becomes an all-channel DNC |
| `salesos.vehicles` | `salesos_ai.vehicles` | `salesos_vehicle_id`; price is stored in cents, and a price cut becomes a `vehicle_events` price_drop |
| AgentPhone line +17542291849 | dealer `SoldByDerek` (`bridge_key='soldbyderek'`), `channel_numbers` provider `agentphone` | |
| `public.leads` (AgentPhone) | contacts + leads in SoldByDerek | `public_lead_id`; `ok_to_text=false` becomes an sms opt-out |
| `public.messages` (AgentPhone) | `salesos_ai.agentphone_inbox` → `agentphone-bridge` | Inbound texts go through the same pipeline as Twilio/WhatsApp: STOP/HELP/START first, then the agent and classification. Outbound texts are mirrored for pacing. |
| `public.calls` (AgentPhone) | `lead_activities` (kind `call`) | An opt-out said on a call becomes a DNC, or an urgent review item |

The triggers on live tables are `AFTER` triggers named `salesos_ai_bridge_trg`. They swallow their own errors, so a SalesOS AI problem can never fail an app write or an AgentPhone webhook.

## Consent policy ("anyone who gave me their number knows")
- **Grant on a provided number.** A lead or customer with a phone gets one `consent_events` grant: source `provided_number_inquiry`, purpose `inquiry_followup`, channel sms.
  - The grant covers replies, inquiry follow-ups, appointments, test drives and transactional texts.
  - It is never re-granted over an opt-out.
- **Marketing needs express written consent.** This covers blasts, re-engagement, and price drops on cars the lead did *not* ask about.
- **A price drop on the car the lead asked about counts as an inquiry follow-up.** "Asked about" means the lead's vehicle: an appointment vehicle, or a VIN or stock number in `vehicle_interest`.
- **These always apply:** STOP/opt-out, DNC, quiet hours (FL state rules on these dealers), and pacing/warm-up (`can_send`).

## Applying changes
- Migrations live in `supabase/migrations/`, and that folder mirrors the live migration history exactly (Derek's 16 plus the `salesos_ai_*` ones).
  - Apply through the Supabase MCP `apply_migration`, or `supabase db push` (the workflow `supabase-deploy.yml`, gated on repo secrets).
- Edge Functions live in `supabase/functions/<name>`, and `verify_jwt` is set per function in `supabase/config.toml`.
  - Webhooks, `unsubscribe` and `mcp` are public and authenticate themselves.
  - The workers, plus `agentphone-bridge`, require the service-role JWT.

## Required one-time setup (by name; values never go in git)
1. **API → Exposed schemas: add `salesos_ai`.** The functions call it through PostgREST.
   - anon and authenticated have no USAGE on the schema, so exposing it does not open it to the public.
2. **Vault:** `project_url`, `service_role_key`. pg_cron uses these to call the workers. Until they are set, every kick is a no-op.
3. **Function secrets:**
   - Core: `PUBLIC_FUNCTIONS_URL`, `UNSUBSCRIBE_BASE_URL`.
   - Twilio: `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`.
   - Meta/WhatsApp: `META_ACCESS_TOKEN`, `META_APP_SECRET`, `META_VERIFY_TOKEN`, `META_API_VERSION`.
   - Resend: `RESEND_API_KEY`, `RESEND_WEBHOOK_SECRET`.
   - AI models: `AI_GATEWAY_API_KEY`, `AGENT_MODEL`, `CLASSIFIER_MODEL`.
   - Embeddings: `EMBEDDINGS_API_KEY`, `EMBEDDINGS_BASE_URL`, `EMBEDDINGS_MODEL`.
   - Other: `PREQUAL_BASE_URL`.
4. **Replies on the AgentPhone line:** there is no AgentPhone send adapter yet. Agent drafts for SoldByDerek fail cleanly with `provider_not_configured` and go to a person instead of sending.
