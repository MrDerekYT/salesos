# Deploying SalesOS

Merging to `main` deploys:

- **Vercel** (GitHub integration) builds and ships the Next.js app.
- **GitHub Actions `Supabase deploy`** runs `supabase db push` (all of `supabase/migrations`, in timestamp order, each once) and `supabase functions deploy`, when `supabase/**` changes. It is a no-op until the repository secrets below exist.
- **GitHub Actions `CI`** builds, type-checks (Next.js + Deno) and runs the unit, SQL and integration tests on every PR and push.

## One-time setup

1. **Repository secrets** (GitHub → Settings → Secrets → Actions): `SUPABASE_ACCESS_TOKEN`, `SUPABASE_PROJECT_REF`, `SUPABASE_DB_PASSWORD`.
2. **Extensions** (Dashboard → Database → Extensions): `pg_cron`, `pg_net`, `vector`. The migrations also try to create them; enabling them first avoids permission surprises.
3. **Vault secrets** used by the cron → Edge Function dispatcher (SQL editor):
   ```sql
   select vault.create_secret('https://<project-ref>.supabase.co', 'project_url');
   select vault.create_secret('<service_role_key>', 'service_role_key');
   ```
4. **Edge Function secrets** (`supabase secrets set --env-file <file>`; names in `.env.example`):
   `PUBLIC_FUNCTIONS_URL`, `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN`, `META_ACCESS_TOKEN`, `META_APP_SECRET`, `META_VERIFY_TOKEN`, `META_API_VERSION`, `RESEND_API_KEY`, `RESEND_WEBHOOK_SECRET`, `UNSUBSCRIBE_BASE_URL`, `AI_GATEWAY_API_KEY`, `AGENT_MODEL`, `CLASSIFIER_MODEL`, `EMBEDDINGS_API_KEY`, `EMBEDDINGS_BASE_URL`, `EMBEDDINGS_MODEL`, `PREQUAL_BASE_URL`. `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` are injected by Supabase. Never set `SALESOS_ALLOW_MOCK_PROVIDER` in production.
5. **Vercel env**: `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `NEXT_PUBLIC_META_APP_ID`, `META_APP_SECRET`, `NEXT_PUBLIC_APP_URL`.
6. **Provider webhooks** → `<PUBLIC_FUNCTIONS_URL>/webhook-twilio`, `/webhook-meta`, `/webhook-resend`.
7. **Channel numbers**: insert `channel_numbers` rows (`provider` + non-secret `provider_config`: `messaging_service_sid`; `phone_number_id` + `waba_id`; `from`).
8. Run one staging smoke test per provider, and have counsel review the state quiet-hours table, before go-live.

## Manual equivalent

```bash
supabase link --project-ref <ref>
supabase db push
supabase functions deploy --use-api
```

## Existing data

If `supabase/schema.sql` was already run by hand, `db push` is still safe: the baseline migration is idempotent, and the tenancy bridge gives every existing user a personal dealer workspace, creates a contact for every lead, maps display stages (`Lead In`, `Negotiation`, `Closed Won`…) to pipeline stages, and fills `value_cents`. Leads without an owner go to an `Unassigned (migrated)` workspace visible only to the service role.
