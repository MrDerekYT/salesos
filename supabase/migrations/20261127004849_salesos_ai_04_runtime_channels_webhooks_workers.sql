-- SalesOS AI package, adapted for the live salesos project: lives in schema salesos_ai (additive; no existing object touched).
-- Source: 20261128090000_runtime_channels_webhooks_workers.sql with public. -> salesos_ai.
set search_path to salesos_ai, extensions, public;
-- =====================================================================================
-- SalesOS phase 4: runtime. Channel providers (Twilio SMS, Meta WhatsApp Cloud, Resend email) with idempotent sends,
-- signed inbound webhooks (event log, threading, STOP/HELP/START first, delivery receipts, template status),
-- agent-runner job lanes (one lane per lead, budget, circuit breaker), classification queue, one-click unsubscribe,
-- rep approval of drafts, and the pg_cron schedule for the workers.
-- Requires the phase 1 and phase 3 migrations. Idempotent: safe to run twice.
--
-- Rule kept from phases 1-3: every Edge Function talks to Postgres through the SQL functions below (RPC only), so
-- the same worker code runs against supabase-js in production and against plain Postgres in the local tests.
-- Pattern attributions (ideas only; all code is original): DeskcommCRM (inbound turn pipeline, keyword-first),
-- AgentSDR (review queue + release), AgenticCRM (circuit breaker), wacrm (per-conversation lanes, 24 h window).
-- =====================================================================================
set search_path to salesos_ai, extensions, public;

-- =====================================================================================
-- PART M. PROVIDERS + IDEMPOTENT SENDS
-- =====================================================================================
alter table salesos_ai.channel_numbers add column if not exists provider_config jsonb not null default '{}'::jsonb;
-- provider_config holds NON-secret ids only: twilio {messaging_service_sid, provider_handles_keywords},
-- meta_cloud {phone_number_id, waba_id}, resend {from_name, reply_to}. Secrets live in Edge Function env vars.
do $$ begin
  alter table salesos_ai.channel_numbers add constraint channel_numbers_provider_ck check (provider in ('twilio','meta_cloud','resend','mock','agentphone'));
exception when duplicate_object then null; end $$;
alter table salesos_ai.dealers add column if not exists postal_address text;       -- CAN-SPAM: required in commercial email
alter table salesos_ai.dealers add column if not exists main_phone text;           -- used in the HELP reply
create index if not exists contacts_dealer_phone_idx on salesos_ai.contacts (dealer_id, phone_e164);
create index if not exists contacts_dealer_email_idx on salesos_ai.contacts (dealer_id, lower(email));

-- A released reservation must not block a retry with the same idempotency key.
drop index if exists salesos_ai.send_reservations_idem_uq;
create unique index if not exists send_reservations_idem_live_uq on salesos_ai.send_reservations (dealer_id, idempotency_key)
  where idempotency_key is not null and status <> 'released';

-- One row per logical send (draft:<id>, plan:<id>:<attempt>, kw:<id>, staff:<provider id>). Guards against double
-- sends when a worker crashes after the provider accepted the message but before we recorded it.
create table if not exists salesos_ai.send_attempts (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references salesos_ai.dealers(id) on delete cascade,
  idempotency_key text not null,
  provider text not null,
  draft_id uuid references salesos_ai.outbound_drafts(id) on delete set null,
  status text not null default 'pending' check (status in ('pending','sent','failed','unknown')),
  provider_message_id text,
  error_code text,
  attempts int not null default 1,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  unique (dealer_id, idempotency_key)
);

-- proceed | already_sent | in_flight | unknown (crashed mid-send on a provider without idempotency: a person checks)
create or replace function salesos_ai.claim_send_attempt(p_dealer_id uuid, p_key text, p_provider text, p_draft_id uuid default null,
  p_idempotent_provider boolean default false, p_stale_after interval default interval '10 minutes', p_now timestamptz default now())
returns table (decision text, provider_message_id text) language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
#variable_conflict use_column
declare a salesos_ai.send_attempts;
begin
  insert into salesos_ai.send_attempts (dealer_id, idempotency_key, provider, draft_id, started_at)
  values (p_dealer_id, p_key, p_provider, p_draft_id, p_now)
  on conflict (dealer_id, idempotency_key) do nothing
  returning * into a;
  if a.id is not null then decision := 'proceed'; return next; return; end if;
  select * into a from salesos_ai.send_attempts s where s.dealer_id = p_dealer_id and s.idempotency_key = p_key for update;
  if a.status = 'sent' then decision := 'already_sent'; provider_message_id := a.provider_message_id; return next; return; end if;
  if a.status = 'unknown' then decision := 'unknown'; return next; return; end if;
  if a.status = 'pending' and a.started_at > p_now - p_stale_after then decision := 'in_flight'; return next; return; end if;
  if a.status = 'pending' and not p_idempotent_provider then
    update salesos_ai.send_attempts set status = 'unknown', finished_at = p_now where id = a.id;
    decision := 'unknown'; return next; return;
  end if;
  -- failed earlier (provider said no), or a stale pending on a provider that dedupes by key: retry with the same key
  update salesos_ai.send_attempts set status = 'pending', attempts = attempts + 1, started_at = p_now, error_code = null where id = a.id;
  decision := 'proceed'; return next;
end $$;

create or replace function salesos_ai.complete_send_attempt(p_dealer_id uuid, p_key text, p_ok boolean, p_provider_message_id text default null,
  p_error_code text default null, p_now timestamptz default now())
returns void language sql security definer set search_path = salesos_ai, pg_temp as $$
  update salesos_ai.send_attempts set status = case when p_ok then 'sent' else 'failed' end, provider_message_id = coalesce(p_provider_message_id, provider_message_id),
         error_code = left(p_error_code, 120), finished_at = p_now
   where dealer_id = p_dealer_id and idempotency_key = p_key
$$;

-- Everything a channel adapter needs for one recipient, in one call (no secrets).
create or replace function salesos_ai.get_send_target(p_number_id uuid, p_contact_id uuid, p_now timestamptz default now())
returns jsonb language sql stable security definer set search_path = salesos_ai, pg_temp as $$
  select jsonb_build_object(
    'dealer_id', d.id, 'dealer_name', d.name, 'postal_address', d.postal_address, 'main_phone', d.main_phone,
    'number', jsonb_build_object('id', n.id, 'channel', n.channel, 'provider', n.provider, 'address', n.address, 'status', n.status, 'config', n.provider_config),
    'contact', jsonb_build_object('id', c.id, 'first_name', c.first_name, 'phone_e164', c.phone_e164, 'email', c.email),
    'whatsapp_window_open', exists (select 1 from salesos_ai.messages m where m.contact_id = c.id and m.channel = 'whatsapp' and m.direction = 'inbound'
                                      and m.created_at > p_now - interval '24 hours'))
    from salesos_ai.channel_numbers n join salesos_ai.dealers d on d.id = n.dealer_id
    join salesos_ai.contacts c on c.id = p_contact_id and c.dealer_id = n.dealer_id
   where n.id = p_number_id
$$;

-- =====================================================================================
-- PART N. CONVERSATIONS, DELIVERY STATUS, WHATSAPP TEMPLATES, WEBHOOK EVENT LOG
-- =====================================================================================
create table if not exists salesos_ai.conversations (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references salesos_ai.dealers(id) on delete cascade,
  contact_id uuid not null references salesos_ai.contacts(id) on delete cascade,
  number_id uuid not null references salesos_ai.channel_numbers(id) on delete cascade,
  channel salesos_ai.channel_kind not null,
  lead_id uuid references salesos_ai.leads(id) on delete set null,
  last_message_at timestamptz, last_inbound_at timestamptz,
  created_at timestamptz not null default now(),
  unique (dealer_id, contact_id, number_id)
);
alter table salesos_ai.messages add column if not exists conversation_id uuid references salesos_ai.conversations(id) on delete set null;
alter table salesos_ai.messages add column if not exists status_updated_at timestamptz;
alter table salesos_ai.messages add column if not exists delivered_at timestamptz;
alter table salesos_ai.messages add column if not exists read_at timestamptz;
alter table salesos_ai.messages add column if not exists error_code text;
alter table salesos_ai.messages add column if not exists template_name text;
alter table salesos_ai.messages add column if not exists media jsonb;
alter table salesos_ai.messages add column if not exists keyword_checked_at timestamptz;   -- STOP/HELP/START handled (webhook retry safety)
create unique index if not exists messages_provider_id_uq on salesos_ai.messages (channel, provider_message_id) where provider_message_id is not null;

-- forward-only status: queued < sending < sent < delivered < read; failed/undelivered can't overwrite delivered/read
create or replace function salesos_ai.message_status_rank(p text) returns int language sql immutable as $$
  select case p when 'queued' then 1 when 'accepted' then 1 when 'sending' then 2 when 'sent' then 3 when 'delivered' then 4 when 'read' then 5
                when 'undelivered' then 3 when 'failed' then 3 else 0 end
$$;

create or replace function salesos_ai.apply_message_status(p_channel salesos_ai.channel_kind, p_provider_message_id text, p_status text,
  p_error_code text default null, p_at timestamptz default now())
returns table (message_id uuid, applied boolean, opted_out boolean) language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
#variable_conflict use_column
declare m salesos_ai.messages; v_new text := lower(p_status);
begin
  select * into m from salesos_ai.messages where channel = p_channel and provider_message_id = p_provider_message_id for update;
  opted_out := false;
  if m.id is null then message_id := null; applied := false; return next; return; end if;
  message_id := m.id;
  if v_new = 'complained' then                                      -- email spam complaint = opt-out of email; status unchanged
    if not exists (select 1 from salesos_ai.contact_dnc x where x.contact_id = m.contact_id and x.cleared_at is null and (x.channel is null or x.channel = 'email')) then
      perform salesos_ai.record_opt_out(m.dealer_id, m.contact_id, 'email', 'inbound_message', jsonb_build_object('complaint', true, 'message_id', m.id), 'spam complaint');
    end if;
    applied := false; opted_out := true; return next; return;
  end if;
  if v_new in ('failed','undelivered') and m.status in ('delivered','read') then applied := false;
  elsif v_new not in ('failed','undelivered') and salesos_ai.message_status_rank(v_new) <= salesos_ai.message_status_rank(m.status) then applied := false;
  else
    update salesos_ai.messages set status = v_new, status_updated_at = p_at, error_code = coalesce(left(p_error_code, 40), error_code),
           delivered_at = case when v_new in ('delivered','read') then coalesce(delivered_at, p_at) else delivered_at end,
           read_at = case when v_new = 'read' then p_at else read_at end
     where id = m.id;
    applied := true;
  end if;
  -- carrier/platform-level opt-outs reported on a failed send are honored like a STOP
  if v_new in ('failed','undelivered') and p_error_code = '21610' then          -- Twilio: recipient replied STOP to this sender
    perform salesos_ai.record_opt_out(m.dealer_id, m.contact_id, 'sms', 'sms_keyword', jsonb_build_object('carrier_error', '21610', 'message_id', m.id), 'carrier-level STOP (21610)');
    opted_out := true;
  elsif v_new = 'failed' and p_error_code = '131050' then                       -- WhatsApp: user stopped marketing messages
    insert into salesos_ai.consent_events (dealer_id, contact_id, channel, purpose, action, source, evidence, note)
    values (m.dealer_id, m.contact_id, 'whatsapp', 'marketing', 'revoke', 'inbound_message', jsonb_build_object('platform_error', '131050', 'message_id', m.id), 'WhatsApp: user stopped marketing messages');
    opted_out := true;
  end if;
  return next;
end $$;

create table if not exists salesos_ai.message_templates (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references salesos_ai.dealers(id) on delete cascade,
  number_id uuid references salesos_ai.channel_numbers(id) on delete cascade,
  provider text not null default 'meta_cloud',
  provider_template_id text,
  name text not null,
  language text not null,
  category text check (category in ('MARKETING','UTILITY','AUTHENTICATION')),
  status text not null default 'PENDING' check (status in ('PENDING','APPROVED','REJECTED','PAUSED','DISABLED','IN_APPEAL','PENDING_DELETION','DELETED','LIMIT_EXCEEDED','FLAGGED','REINSTATED')),
  body_text text,                                             -- with {{1}}..{{n}} placeholders
  param_count int not null default 0,
  salesos_use text,                                           -- reengage | price_drop | service_due | lease_end | ...
  rejected_reason text,
  last_synced_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (dealer_id, name, language)
);

-- pull sync (Graph API list) => upsert; templates missing from the list are marked DELETED
create or replace function salesos_ai.upsert_message_templates(p_number_id uuid, p_templates jsonb, p_now timestamptz default now())
returns int language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare v_dealer uuid; v_n int;
begin
  select dealer_id into v_dealer from salesos_ai.channel_numbers where id = p_number_id and provider = 'meta_cloud';
  if v_dealer is null then raise exception 'not a meta_cloud number: %', p_number_id; end if;
  insert into salesos_ai.message_templates as t (dealer_id, number_id, provider_template_id, name, language, category, status, body_text, param_count, rejected_reason, last_synced_at, updated_at)
  select v_dealer, p_number_id, x->>'id', x->>'name', x->>'language', upper(x->>'category'), upper(x->>'status'), x->>'body_text',
         coalesce((x->>'param_count')::int, 0), nullif(nullif(x->>'rejected_reason', ''), 'NONE'), p_now, p_now
    from jsonb_array_elements(coalesce(p_templates, '[]'::jsonb)) x
  on conflict (dealer_id, name, language) do update
     set provider_template_id = excluded.provider_template_id, category = excluded.category, status = excluded.status,
         body_text = excluded.body_text, param_count = excluded.param_count, rejected_reason = excluded.rejected_reason,
         number_id = excluded.number_id, last_synced_at = p_now, updated_at = p_now;
  get diagnostics v_n = row_count;
  update salesos_ai.message_templates set status = 'DELETED', updated_at = p_now
   where dealer_id = v_dealer and number_id = p_number_id and status <> 'DELETED'
     and (name, language) not in (select x->>'name', x->>'language' from jsonb_array_elements(coalesce(p_templates, '[]'::jsonb)) x);
  return v_n;
end $$;

-- push sync (message_template_status_update webhook), keyed by the WABA id on the number's provider_config
create or replace function salesos_ai.apply_template_status(p_waba_id text, p_provider_template_id text, p_name text, p_language text,
  p_status text, p_reason text default null, p_now timestamptz default now())
returns int language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare v_n int;
begin
  update salesos_ai.message_templates t set status = upper(p_status), rejected_reason = nullif(p_reason, 'NONE'),
         provider_template_id = coalesce(p_provider_template_id, t.provider_template_id), last_synced_at = p_now, updated_at = p_now
   where t.number_id in (select id from salesos_ai.channel_numbers where provider = 'meta_cloud' and provider_config->>'waba_id' = p_waba_id)
     and (t.provider_template_id = p_provider_template_id or (t.name = p_name and (p_language is null or t.language = p_language)));
  get diagnostics v_n = row_count;
  return v_n;
end $$;

create or replace function salesos_ai.list_template_numbers()
returns table (number_id uuid, dealer_id uuid, waba_id text) language sql stable security definer set search_path = salesos_ai, pg_temp as $$
  select id, dealer_id, provider_config->>'waba_id' from salesos_ai.channel_numbers
   where provider = 'meta_cloud' and status in ('active','paused') and coalesce(provider_config->>'waba_id', '') <> ''
$$;

-- an approved template for a use (marketing purposes need a MARKETING template; everything else UTILITY)
create or replace function salesos_ai.pick_whatsapp_template(p_number_id uuid, p_use text, p_purpose salesos_ai.consent_purpose)
returns table (name text, language text, body_text text, param_count int) language sql stable security definer set search_path = salesos_ai, pg_temp as $$
  select t.name, t.language, t.body_text, t.param_count from salesos_ai.message_templates t
   where t.number_id = p_number_id and t.status = 'APPROVED'
     and t.category = case when p_purpose = 'marketing' then 'MARKETING' else 'UTILITY' end
     and coalesce(t.salesos_use, 'reengage') in (p_use, 'reengage')
   order by (coalesce(t.salesos_use, 'reengage') = p_use) desc, t.updated_at desc
   limit 1
$$;

create table if not exists salesos_ai.event_log (
  id uuid primary key default gen_random_uuid(),
  provider text not null check (provider in ('twilio','meta_cloud','resend','unsubscribe','agentphone')),
  external_id text not null,                                  -- MessageSid:status / wamid:status / svix-id
  event_type text not null,
  dealer_id uuid references salesos_ai.dealers(id) on delete cascade,
  payload jsonb not null default '{}'::jsonb,                 -- raw provider payload (PII: pruned after 30 days)
  status text not null default 'received' check (status in ('received','processed','ignored','failed')),
  error text,
  attempts int not null default 1,
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  unique (provider, external_id)
);
create index if not exists event_log_received_idx on salesos_ai.event_log (received_at);

-- idempotent receipt: a retry of a processed event returns duplicate=true; a failed (or long-stuck) one is re-processed
create or replace function salesos_ai.log_webhook_event(p_provider text, p_external_id text, p_event_type text, p_payload jsonb, p_now timestamptz default now())
returns table (event_id uuid, duplicate boolean) language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
#variable_conflict use_column
declare e salesos_ai.event_log;
begin
  insert into salesos_ai.event_log (provider, external_id, event_type, payload, received_at)
  values (p_provider, p_external_id, p_event_type, coalesce(p_payload, '{}'::jsonb), p_now)
  on conflict (provider, external_id) do nothing returning * into e;
  if e.id is not null then event_id := e.id; duplicate := false; return next; return; end if;
  select * into e from salesos_ai.event_log where provider = p_provider and external_id = p_external_id for update;
  if e.status in ('processed','ignored') or (e.status = 'received' and e.received_at > p_now - interval '2 minutes') then
    event_id := e.id; duplicate := true; return next; return;
  end if;
  update salesos_ai.event_log set attempts = attempts + 1, status = 'received', error = null, received_at = p_now where id = e.id;
  event_id := e.id; duplicate := false; return next;
end $$;

create or replace function salesos_ai.finish_webhook_event(p_event_id uuid, p_status text, p_error text default null, p_dealer_id uuid default null, p_now timestamptz default now())
returns void language sql security definer set search_path = salesos_ai, pg_temp as $$
  update salesos_ai.event_log set status = p_status, error = left(p_error, 500), dealer_id = coalesce(p_dealer_id, dealer_id), processed_at = p_now where id = p_event_id
$$;

-- =====================================================================================
-- PART O. INBOUND: number lookup, threading, keywords first (STOP/HELP/START), queues
-- =====================================================================================
create or replace function salesos_ai.resolve_inbound_number(p_channel salesos_ai.channel_kind, p_address text)
returns table (number_id uuid, dealer_id uuid, provider text, config jsonb, dealer_name text, main_phone text, address text, channel salesos_ai.channel_kind)
language sql stable security definer set search_path = salesos_ai, pg_temp as $$
  select n.id, n.dealer_id, n.provider, n.provider_config, d.name, d.main_phone, n.address, n.channel
    from salesos_ai.channel_numbers n join salesos_ai.dealers d on d.id = n.dealer_id
   where n.channel = p_channel and n.status in ('active','paused')
     and (n.address = case when p_channel = 'email' then lower(btrim(p_address)) else btrim(p_address) end
          or (p_channel = 'whatsapp' and n.provider_config->>'phone_number_id' = btrim(p_address)))
   order by n.status = 'active' desc limit 1
$$;

create table if not exists salesos_ai.agent_jobs (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references salesos_ai.dealers(id) on delete cascade,
  lead_id uuid not null references salesos_ai.leads(id) on delete cascade,
  contact_id uuid not null references salesos_ai.contacts(id) on delete cascade,
  trigger salesos_ai.agent_trigger not null default 'inbound_message',
  trigger_ref uuid,                                           -- latest inbound message folded into this job
  status text not null default 'queued' check (status in ('queued','running','done','skipped','escalated','dead')),
  attempts int not null default 0,
  max_attempts int not null default 3,
  not_before timestamptz not null default now(),
  locked_at timestamptz, locked_by text,
  run_id uuid references salesos_ai.agent_runs(id) on delete set null,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- the lane: at most one queued and one running job per lead
create unique index if not exists agent_jobs_queued_lane_uq on salesos_ai.agent_jobs (lead_id) where status = 'queued';
create unique index if not exists agent_jobs_running_lane_uq on salesos_ai.agent_jobs (lead_id) where status = 'running';
create index if not exists agent_jobs_due_idx on salesos_ai.agent_jobs (not_before) where status = 'queued';

-- a new inbound while a job is still queued folds into it (debounces bursts: "hi" / "is the truck there?" / "the red one")
create or replace function salesos_ai.enqueue_agent_job(p_lead_id uuid, p_message_id uuid, p_debounce_seconds int default 4, p_now timestamptz default now())
returns uuid language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare l salesos_ai.leads; v_id uuid;
begin
  select * into l from salesos_ai.leads where id = p_lead_id;
  if l.id is null then raise exception 'lead % not found', p_lead_id; end if;
  insert into salesos_ai.agent_jobs (dealer_id, lead_id, contact_id, trigger, trigger_ref, not_before, created_at, updated_at)
  values (l.dealer_id, l.id, l.contact_id, 'inbound_message', p_message_id, p_now + make_interval(secs => p_debounce_seconds), p_now, p_now)
  on conflict (lead_id) where status = 'queued'
  do update set trigger_ref = excluded.trigger_ref, not_before = greatest(salesos_ai.agent_jobs.not_before, excluded.not_before), updated_at = p_now
  returning id into v_id;
  return v_id;
end $$;

create table if not exists salesos_ai.classify_queue (
  message_id uuid primary key references salesos_ai.messages(id) on delete cascade,
  dealer_id uuid not null references salesos_ai.dealers(id) on delete cascade,
  attempts int not null default 0,
  not_before timestamptz not null default now(),
  locked_at timestamptz,
  last_error text,
  created_at timestamptz not null default now()
);

create table if not exists salesos_ai.keyword_replies (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references salesos_ai.dealers(id) on delete cascade,
  contact_id uuid not null references salesos_ai.contacts(id) on delete cascade,
  channel salesos_ai.channel_kind not null,
  kind text not null check (kind in ('stop','help','start')),
  trigger_message_id uuid references salesos_ai.messages(id) on delete set null,
  consent_event_id uuid references salesos_ai.consent_events(id) on delete set null,
  sent_message_id uuid references salesos_ai.messages(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists keyword_replies_contact_idx on salesos_ai.keyword_replies (contact_id, channel, kind, created_at desc);

create or replace function salesos_ai.ingest_inbound_message(p_number_id uuid, p_from text, p_body text, p_provider_message_id text,
  p_received_at timestamptz default now(), p_media jsonb default null, p_first_name text default null)
returns table (message_id uuid, dealer_id uuid, contact_id uuid, lead_id uuid, conversation_id uuid, duplicate boolean)
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
#variable_conflict use_column
declare n salesos_ai.channel_numbers; v_from text; v_contact uuid; v_lead uuid; v_conv uuid; v_msg uuid;
begin
  select * into n from salesos_ai.channel_numbers where id = p_number_id;
  if n.id is null then raise exception 'number % not found', p_number_id; end if;
  if coalesce(p_provider_message_id, '') = '' then raise exception 'invalid: provider message id required' using errcode = '22023'; end if;
  v_from := case when n.channel = 'email' then lower(btrim(p_from)) else btrim(p_from) end;
  if n.channel <> 'email' and v_from !~ '^\+[1-9][0-9]{6,14}$' then raise exception 'invalid sender address %', v_from using errcode = '22023'; end if;
  -- idempotent on the provider id (webhook retries)
  select m.id, m.contact_id, m.lead_id, m.conversation_id into v_msg, v_contact, v_lead, v_conv
    from salesos_ai.messages m where m.channel = n.channel and m.provider_message_id = p_provider_message_id;
  if v_msg is not null then
    message_id := v_msg; dealer_id := n.dealer_id; contact_id := v_contact; lead_id := v_lead; conversation_id := v_conv; duplicate := true;
    return next; return;
  end if;
  perform pg_advisory_xact_lock(hashtextextended(n.dealer_id::text || ':' || v_from, 0));     -- no duplicate contacts on parallel webhooks
  select c.id into v_contact from salesos_ai.contacts c
   where c.dealer_id = n.dealer_id and ((n.channel <> 'email' and c.phone_e164 = v_from) or (n.channel = 'email' and lower(c.email) = v_from))
   order by c.created_at limit 1;
  if v_contact is null then
    insert into salesos_ai.contacts (dealer_id, first_name, phone_e164, email)
    values (n.dealer_id, nullif(btrim(p_first_name), ''), case when n.channel <> 'email' then v_from end, case when n.channel = 'email' then v_from end)
    returning id into v_contact;
  end if;
  select l.id into v_lead from salesos_ai.leads l where l.contact_id = v_contact and coalesce(l.stage, 'new') not in ('won','lost')
   order by l.created_at desc limit 1;
  if v_lead is null then
    insert into salesos_ai.leads (dealer_id, contact_id, stage) values (n.dealer_id, v_contact, 'new') returning id into v_lead;
  end if;
  insert into salesos_ai.conversations as cv (dealer_id, contact_id, number_id, channel, lead_id, last_message_at, last_inbound_at)
  values (n.dealer_id, v_contact, n.id, n.channel, v_lead, p_received_at, p_received_at)
  on conflict (dealer_id, contact_id, number_id) do update
     set lead_id = excluded.lead_id, last_message_at = greatest(cv.last_message_at, excluded.last_message_at),
         last_inbound_at = greatest(cv.last_inbound_at, excluded.last_inbound_at)
  returning id into v_conv;
  -- fires messages_after_insert (context_version++, stale AI drafts) and the follow-up stop trigger
  insert into salesos_ai.messages (dealer_id, lead_id, contact_id, number_id, conversation_id, channel, direction, author_kind, body, provider_message_id, status, media, created_at)
  values (n.dealer_id, v_lead, v_contact, n.id, v_conv, n.channel, 'inbound', 'contact', left(coalesce(p_body, ''), 4000), p_provider_message_id, 'received', p_media, p_received_at)
  returning id into v_msg;
  message_id := v_msg; dealer_id := n.dealer_id; contact_id := v_contact; lead_id := v_lead; conversation_id := v_conv; duplicate := false;
  return next;
end $$;

-- Runs BEFORE any AI sees the message. p_level comes from classifyInbound() (opt-out.ts).
-- reply_kind (stop|help|start) is set only when a reply is due: STOP is confirmed once per opt-out, START once per
-- re-opt-in, HELP at most hourly. probable_stop silences the AI and opens an urgent item; nothing is sent.
create or replace function salesos_ai.apply_inbound_keyword(p_message_id uuid, p_level text, p_scope text default 'channel', p_matched text default null,
  p_legal_threat boolean default false, p_provider_handles_reply boolean default false, p_now timestamptz default now())
returns table (action text, reply_kind text, keyword_reply_id uuid, consent_event_id uuid)
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
#variable_conflict use_column
declare m salesos_ai.messages; v_ce uuid; v_since timestamptz; v_kr uuid;
begin
  perform 1 from salesos_ai.messages where id = p_message_id for update;
  select * into m from salesos_ai.messages where id = p_message_id and direction = 'inbound';
  if m.id is null then raise exception 'inbound message % not found', p_message_id; end if;
  perform pg_advisory_xact_lock(hashtextextended('kw:' || m.contact_id::text || ':' || m.channel::text, 0));
  if m.keyword_checked_at is not null then
    -- webhook retry after a crash: never re-record; hand back a confirmation that was claimed but not yet sent
    action := 'already_processed';
    select k.kind, k.id into reply_kind, keyword_reply_id from salesos_ai.keyword_replies k where k.trigger_message_id = m.id and k.sent_message_id is null limit 1;
    return next; return;
  end if;
  update salesos_ai.messages set keyword_checked_at = p_now where id = m.id;
  action := 'agent';
  if p_level = 'stop' then
    v_ce := salesos_ai.record_opt_out(m.dealer_id, m.contact_id, case when p_scope = 'all_channels' then null else m.channel end,
                                  (case when m.channel = 'sms' then 'sms_keyword' else 'inbound_message' end)::salesos_ai.consent_source,
                                  jsonb_build_object('message_id', m.id, 'matched', p_matched), coalesce('inbound: ' || p_matched, 'STOP'));
    action := 'opted_out'; consent_event_id := v_ce;
    -- opt-out cycle = since the last grant; compared on consent_events' own clock (DB time), never mixed with p_now
    select max(c.created_at) into v_since from salesos_ai.consent_events c where c.contact_id = m.contact_id and c.action = 'grant' and c.channel = m.channel;
    if not p_provider_handles_reply and not exists (select 1 from salesos_ai.keyword_replies k left join salesos_ai.consent_events ce on ce.id = k.consent_event_id
                     where k.contact_id = m.contact_id and k.channel = m.channel and k.kind = 'stop'
                       and coalesce(ce.created_at, k.created_at) > coalesce(v_since, '-infinity')) then
      insert into salesos_ai.keyword_replies (dealer_id, contact_id, channel, kind, trigger_message_id, consent_event_id, created_at)
      values (m.dealer_id, m.contact_id, m.channel, 'stop', m.id, v_ce, p_now) returning id into v_kr;
      reply_kind := 'stop'; keyword_reply_id := v_kr;
    end if;
  elsif p_level = 'start' and exists (select 1 from salesos_ai.contact_dnc x where x.contact_id = m.contact_id and x.cleared_at is null and x.channel is null) then
    -- an all-channel Do-Not-Contact is cleared only through the DNC process, never by a keyword
    insert into salesos_ai.agent_inbox_items (dealer_id, lead_id, kind, priority, title, summary, payload)
    values (m.dealer_id, m.lead_id, 'needs_review', 2, 'Customer texted START but is on Do-Not-Contact', left(m.body, 280), jsonb_build_object('message_id', m.id))
    on conflict (lead_id, kind) where status = 'open' and lead_id is not null do nothing;
    action := 'start_blocked';
  elsif p_level = 'start' then
    insert into salesos_ai.consent_events (dealer_id, contact_id, channel, purpose, action, source, evidence, note)
    values (m.dealer_id, m.contact_id, m.channel, 'conversational', 'grant', (case when m.channel = 'sms' then 'sms_keyword' else 'inbound_message' end)::salesos_ai.consent_source,
            jsonb_build_object('message_id', m.id, 'matched', p_matched), 'START keyword') returning id into v_ce;
    action := 'opted_in'; consent_event_id := v_ce;
    select max(c.created_at) into v_since from salesos_ai.consent_events c where c.contact_id = m.contact_id and c.action = 'revoke' and (c.channel = m.channel or c.channel is null);
    if not p_provider_handles_reply and not exists (select 1 from salesos_ai.keyword_replies k left join salesos_ai.consent_events ce on ce.id = k.consent_event_id
                     where k.contact_id = m.contact_id and k.channel = m.channel and k.kind = 'start'
                       and coalesce(ce.created_at, k.created_at) > coalesce(v_since, '-infinity')) then
      insert into salesos_ai.keyword_replies (dealer_id, contact_id, channel, kind, trigger_message_id, consent_event_id, created_at)
      values (m.dealer_id, m.contact_id, m.channel, 'start', m.id, v_ce, p_now) returning id into v_kr;
      reply_kind := 'start'; keyword_reply_id := v_kr;
    end if;
  elsif p_level = 'help' then
    action := 'help';
    if not p_provider_handles_reply and not exists (select 1 from salesos_ai.keyword_replies k where k.contact_id = m.contact_id and k.channel = m.channel
                     and k.kind = 'help' and k.created_at > p_now - interval '1 hour') then
      insert into salesos_ai.keyword_replies (dealer_id, contact_id, channel, kind, trigger_message_id, created_at)
      values (m.dealer_id, m.contact_id, m.channel, 'help', m.id, p_now) returning id into v_kr;
      reply_kind := 'help'; keyword_reply_id := v_kr;
    end if;
  elsif p_level = 'probable_stop' then
    update salesos_ai.leads set force_human = true, bot_silenced_until = p_now + interval '30 days', updated_at = p_now where id = m.lead_id;
    insert into salesos_ai.agent_inbox_items (dealer_id, lead_id, kind, priority, title, summary, payload)
    values (m.dealer_id, m.lead_id, (case when p_legal_threat then 'legal_threat' else 'ambiguous_stop' end)::salesos_ai.inbox_kind, 1,
            case when p_legal_threat then 'Legal language from a customer' else 'Possible opt-out: please review' end,
            left(m.body, 280), jsonb_build_object('message_id', m.id, 'matched', p_matched))
    on conflict (lead_id, kind) where status = 'open' and lead_id is not null do nothing;
    action := 'silenced';
  end if;
  if action in ('opted_out','silenced') and m.lead_id is not null then
    -- nothing queued for this lead may run after an opt-out (the gates would veto anyway; this saves the model call)
    update salesos_ai.agent_jobs set status = 'skipped', last_error = 'customer opted out', updated_at = p_now where lead_id = m.lead_id and status = 'queued';
    delete from salesos_ai.classify_queue where message_id in (select id from salesos_ai.messages where lead_id = m.lead_id);
  end if;
  if action = 'agent' and m.lead_id is not null then
    perform salesos_ai.enqueue_agent_job(m.lead_id, m.id, 4, p_now);
    insert into salesos_ai.classify_queue (message_id, dealer_id, not_before) values (m.id, m.dealer_id, p_now) on conflict do nothing;
  end if;
  return next;
end $$;

-- System replies (keyword confirmations, staff command replies) bypass can_send: they answer the sender's own message,
-- carry no marketing, and keyword confirmations are claimed at most once (apply_inbound_keyword).
create or replace function salesos_ai.record_system_message(p_number_id uuid, p_to_contact_id uuid, p_body text, p_provider_message_id text,
  p_status text, p_keyword_reply_id uuid default null, p_error text default null, p_now timestamptz default now())
returns uuid language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare n salesos_ai.channel_numbers; v_lead uuid; v_conv uuid; v_id uuid;
begin
  select * into n from salesos_ai.channel_numbers where id = p_number_id;
  select id, lead_id into v_conv, v_lead from salesos_ai.conversations where contact_id = p_to_contact_id and number_id = p_number_id;
  insert into salesos_ai.messages (dealer_id, lead_id, contact_id, number_id, conversation_id, channel, direction, author_kind, body, provider_message_id, status, error_code, created_at)
  values (n.dealer_id, v_lead, p_to_contact_id, n.id, v_conv, n.channel, 'outbound', 'system', p_body, p_provider_message_id, p_status, left(p_error, 40), p_now)
  returning id into v_id;
  if p_keyword_reply_id is not null then update salesos_ai.keyword_replies set sent_message_id = v_id where id = p_keyword_reply_id; end if;
  return v_id;
end $$;

-- ---------- classification queue ----------
create or replace function salesos_ai.claim_classification_jobs(p_limit int default 20, p_now timestamptz default now())
returns table (message_id uuid, dealer_id uuid, body text, context_version int, lead_stage text, vehicle text)
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
#variable_conflict use_column
begin
  return query
  with c as (
    update salesos_ai.classify_queue q set locked_at = p_now, attempts = q.attempts + 1
     where q.message_id in (select q2.message_id from salesos_ai.classify_queue q2
                             where q2.not_before <= p_now and (q2.locked_at is null or q2.locked_at < p_now - interval '5 minutes') and q2.attempts < 5
                             order by q2.created_at for update skip locked limit p_limit)
    returning q.message_id)
  select m.id, m.dealer_id, m.body, l.context_version, l.stage, nullif(concat_ws(' ', v.year, v.make, v.model), '')
    from c join salesos_ai.messages m on m.id = c.message_id join salesos_ai.leads l on l.id = m.lead_id
    left join salesos_ai.vehicles v on v.id = l.vehicle_id;
end $$;

create or replace function salesos_ai.finish_classification_job(p_message_id uuid, p_ok boolean, p_error text default null, p_now timestamptz default now())
returns void language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
begin
  if p_ok then delete from salesos_ai.classify_queue where message_id = p_message_id;
  else update salesos_ai.classify_queue set locked_at = null, last_error = left(p_error, 300),
              not_before = p_now + make_interval(mins => power(2, least(attempts, 6))::int) where message_id = p_message_id;
  end if;
end $$;

-- =====================================================================================
-- PART P. AGENT RUNNER: lane claims, run start/finish (budget + breaker), tool RPCs
-- =====================================================================================
-- Stale running jobs (worker died) go back to the queue, unless a newer job already waits in the lane (it supersedes).
create or replace function salesos_ai.claim_agent_jobs(p_worker text, p_limit int default 10, p_now timestamptz default now())
returns setof salesos_ai.agent_jobs language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
begin
  update salesos_ai.agent_jobs j set status = 'skipped', last_error = 'superseded after worker timeout', updated_at = p_now
   where j.status = 'running' and j.locked_at < p_now - interval '5 minutes'
     and exists (select 1 from salesos_ai.agent_jobs q where q.lead_id = j.lead_id and q.status = 'queued');
  update salesos_ai.agent_jobs j set status = 'queued', locked_at = null, locked_by = null, last_error = 'worker timeout', updated_at = p_now
   where j.status = 'running' and j.locked_at < p_now - interval '5 minutes';
  return query
  update salesos_ai.agent_jobs j set status = 'running', attempts = j.attempts + 1, locked_at = p_now, locked_by = p_worker, updated_at = p_now
   where j.id in (select q.id from salesos_ai.agent_jobs q
                   where q.status = 'queued' and q.not_before <= p_now
                     and not exists (select 1 from salesos_ai.agent_jobs r where r.lead_id = q.lead_id and r.status = 'running')
                   order by q.not_before for update skip locked limit p_limit)
  returning j.*;
end $$;

-- run | skipped_human | breaker_open | budget_blocked
create or replace function salesos_ai.start_agent_run(p_job_id uuid, p_estimate_cents numeric, p_model text default null, p_prompt_version text default null,
  p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare j salesos_ai.agent_jobs; l salesos_ai.leads; v_run uuid;
begin
  select * into j from salesos_ai.agent_jobs where id = p_job_id and status = 'running';
  if j.id is null then raise exception 'job % is not running', p_job_id; end if;
  select * into l from salesos_ai.leads where id = j.lead_id;
  if l.force_human or (l.bot_silenced_until is not null and l.bot_silenced_until > p_now) then
    return jsonb_build_object('outcome', 'skipped_human');
  end if;
  if salesos_ai.agent_breaker_open(j.dealer_id, p_now) then
    insert into salesos_ai.agent_inbox_items (dealer_id, lead_id, kind, priority, title, summary, payload)
    values (j.dealer_id, j.lead_id, 'handoff', 1, 'Customer waiting: assistant paused', 'The AI model is failing repeatedly, so the assistant is paused. Please reply personally.',
            jsonb_build_object('reason', 'circuit_breaker', 'message_id', j.trigger_ref))
    on conflict (lead_id, kind) where status = 'open' and lead_id is not null do nothing;
    return jsonb_build_object('outcome', 'breaker_open');
  end if;
  if not salesos_ai.ai_budget_reserve(j.dealer_id, p_estimate_cents, p_now) then
    insert into salesos_ai.agent_runs (dealer_id, lead_id, contact_id, trigger, trigger_ref, status, model, prompt_version, error, started_at, finished_at)
    values (j.dealer_id, j.lead_id, j.contact_id, j.trigger, j.trigger_ref, 'budget_blocked', p_model, p_prompt_version, 'monthly AI budget reached', p_now, p_now)
    returning id into v_run;
    insert into salesos_ai.agent_inbox_items (dealer_id, lead_id, run_id, kind, priority, title, summary)
    values (j.dealer_id, j.lead_id, v_run, 'budget_blocked', 1, 'Customer waiting: AI budget reached', 'The monthly AI budget is used up. Reply personally or raise the cap.')
    on conflict (lead_id, kind) where status = 'open' and lead_id is not null do nothing;
    update salesos_ai.agent_jobs set run_id = v_run where id = j.id;
    return jsonb_build_object('outcome', 'budget_blocked', 'run_id', v_run);
  end if;
  insert into salesos_ai.agent_runs (dealer_id, lead_id, contact_id, trigger, trigger_ref, status, model, prompt_version, started_at)
  values (j.dealer_id, j.lead_id, j.contact_id, j.trigger, j.trigger_ref, 'running', p_model, p_prompt_version, p_now)
  returning id into v_run;
  update salesos_ai.agent_jobs set run_id = v_run where id = j.id;
  return jsonb_build_object('outcome', 'run', 'run_id', v_run, 'context_version', l.context_version);
end $$;

create or replace function salesos_ai.finish_agent_run(p_run_id uuid, p_status salesos_ai.agent_run_status, p_steps int, p_input_tokens int, p_output_tokens int,
  p_cost_cents numeric, p_estimate_cents numeric, p_error text default null, p_now timestamptz default now())
returns void language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare r salesos_ai.agent_runs;
begin
  select * into r from salesos_ai.agent_runs where id = p_run_id for update;
  if r.id is null then raise exception 'run % not found', p_run_id; end if;
  if r.status <> 'running' then return; end if;                -- finished already (idempotent)
  perform salesos_ai.ai_budget_settle(r.dealer_id, p_estimate_cents, coalesce(p_cost_cents, 0));
  update salesos_ai.agent_runs set status = p_status, steps = coalesce(p_steps, 0), input_tokens = coalesce(p_input_tokens, 0), output_tokens = coalesce(p_output_tokens, 0),
         cost_cents = coalesce(p_cost_cents, 0), error = left(p_error, 500), finished_at = p_now where id = r.id;
end $$;

-- done | skipped | escalated | retry (backoff 1/2/4 min; after max_attempts the job dies and a person gets the lead)
create or replace function salesos_ai.finish_agent_job(p_job_id uuid, p_outcome text, p_error text default null, p_now timestamptz default now())
returns text language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare j salesos_ai.agent_jobs;
begin
  select * into j from salesos_ai.agent_jobs where id = p_job_id for update;
  if j.id is null then raise exception 'job % not found', p_job_id; end if;
  if p_outcome in ('done','skipped','escalated') then
    update salesos_ai.agent_jobs set status = p_outcome, last_error = left(p_error, 300), locked_at = null, updated_at = p_now where id = j.id;
    return p_outcome;
  end if;
  if p_outcome <> 'retry' then raise exception 'invalid outcome %', p_outcome using errcode = '22023'; end if;
  if j.attempts >= j.max_attempts then
    update salesos_ai.agent_jobs set status = 'dead', last_error = left(p_error, 300), locked_at = null, updated_at = p_now where id = j.id;
    insert into salesos_ai.agent_inbox_items (dealer_id, lead_id, run_id, kind, priority, title, summary, payload)
    values (j.dealer_id, j.lead_id, j.run_id, 'handoff', 1, 'Customer waiting: assistant could not reply', 'The assistant failed several times on this message. Please reply personally.',
            jsonb_build_object('reason', 'agent_job_dead', 'error', left(p_error, 200), 'message_id', j.trigger_ref))
    on conflict (lead_id, kind) where status = 'open' and lead_id is not null do nothing;
    return 'dead';
  end if;
  if exists (select 1 from salesos_ai.agent_jobs q where q.lead_id = j.lead_id and q.status = 'queued') then
    update salesos_ai.agent_jobs set status = 'skipped', last_error = left(coalesce(p_error, '') || ' (superseded by newer message)', 300), locked_at = null, updated_at = p_now where id = j.id;
    return 'skipped';
  end if;
  update salesos_ai.agent_jobs set status = 'queued', last_error = left(p_error, 300), locked_at = null, locked_by = null,
         not_before = p_now + make_interval(mins => power(2, greatest(j.attempts - 1, 0))::int), updated_at = p_now where id = j.id;
  return 'queued';
end $$;

-- Everything the runner prompt needs, in one call. Bodies are returned for the prompt only; the runner marks them untrusted.
create or replace function salesos_ai.get_agent_turn_context(p_job_id uuid, p_limit int default 12)
returns jsonb language sql stable security definer set search_path = salesos_ai, pg_temp as $$
  select jsonb_build_object(
    'job', jsonb_build_object('id', j.id, 'trigger_ref', j.trigger_ref, 'attempts', j.attempts),
    'dealer', jsonb_build_object('id', d.id, 'name', d.name, 'timezone', d.timezone, 'main_phone', d.main_phone),
    'lead', jsonb_build_object('id', l.id, 'stage', l.stage, 'context_version', l.context_version,
                               'vehicle', (select jsonb_build_object('vin', v.vin, 'year', v.year, 'make', v.make, 'model', v.model) from salesos_ai.vehicles v where v.id = l.vehicle_id)),
    'contact', jsonb_build_object('id', c.id, 'first_name', c.first_name),
    'channel', coalesce((select m.channel from salesos_ai.messages m where m.id = j.trigger_ref), 'sms'),
    'number_id', (select m.number_id from salesos_ai.messages m where m.id = j.trigger_ref),
    'messages', coalesce((select jsonb_agg(x order by x.at) from (
        select m.direction, m.author_kind, m.body, m.created_at as at, m.channel from salesos_ai.messages m
         where m.lead_id = l.id order by m.created_at desc limit p_limit) x), '[]'::jsonb),
    'facts', coalesce((select jsonb_object_agg(f.fact_key, f.value) from salesos_ai.customer_facts f where f.lead_id = l.id and f.superseded_at is null), '{}'::jsonb))
    from salesos_ai.agent_jobs j join salesos_ai.leads l on l.id = j.lead_id join salesos_ai.contacts c on c.id = j.contact_id join salesos_ai.dealers d on d.id = j.dealer_id
   where j.id = p_job_id
$$;

-- p: {dealer_id, lead_id, contact_id, channel, number_id, run_id, actor, purpose, kind, reply_for_message_id, body_ai, status, release_at,
--     expected_context_version, evidence, chain_version, veto_code, reservation_id}
create or replace function salesos_ai.agent_record_draft(p jsonb)
returns uuid language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare v_id uuid;
begin
  insert into salesos_ai.outbound_drafts (id, dealer_id, lead_id, contact_id, channel, number_id, run_id, actor, purpose, kind, reply_for_message_id, body_ai,
                                      status, release_at, expected_context_version, evidence, chain_version, veto_code, reservation_id)
  values (coalesce((p->>'id')::uuid, gen_random_uuid()), (p->>'dealer_id')::uuid, (p->>'lead_id')::uuid, (p->>'contact_id')::uuid, (p->>'channel')::salesos_ai.channel_kind, (p->>'number_id')::uuid,
          (p->>'run_id')::uuid, coalesce(p->>'actor', 'ai'), coalesce(p->>'purpose', 'conversational')::salesos_ai.consent_purpose,
          coalesce(p->>'kind', 'reply')::salesos_ai.send_kind, (p->>'reply_for_message_id')::uuid, p->>'body_ai', coalesce(p->>'status', 'awaiting_review'),
          (p->>'release_at')::timestamptz, (p->>'expected_context_version')::int, coalesce(p->'evidence', '{}'::jsonb), (p->>'chain_version')::int,
          p->>'veto_code', (p->>'reservation_id')::uuid)
  returning id into v_id;
  return v_id;
end $$;

create or replace function salesos_ai.insert_before_send_traces(p_draft_id uuid, p_run_id uuid, p_chain_version int, p_traces jsonb, p_attempt int default 1)
returns int language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare v_dealer uuid; v_n int;
begin
  select dealer_id into v_dealer from salesos_ai.outbound_drafts where id = p_draft_id;
  if v_dealer is null then select dealer_id into v_dealer from salesos_ai.agent_runs where id = p_run_id; end if;
  insert into salesos_ai.before_send_traces (dealer_id, draft_id, run_id, attempt, chain_version, gate, verdict, code, detail)
  select v_dealer, p_draft_id, p_run_id, p_attempt, p_chain_version, t->>'gate', t->>'verdict', t->>'code', coalesce(t->'detail', '{}'::jsonb)
    from jsonb_array_elements(coalesce(p_traces, '[]'::jsonb)) t;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

create or replace function salesos_ai.agent_record_tool_call(p_run_id uuid, p_step int, p_tool text, p_args jsonb, p_result_code text, p_duration_ms int)
returns void language sql security definer set search_path = salesos_ai, pg_temp as $$
  insert into salesos_ai.agent_tool_calls (run_id, dealer_id, step, tool, args, result_code, duration_ms)
  select r.id, r.dealer_id, coalesce(p_step, 0), p_tool, coalesce(p_args, '{}'::jsonb), p_result_code, p_duration_ms from salesos_ai.agent_runs r where r.id = p_run_id
$$;

create or replace function salesos_ai.agent_schedule_followup(p_run_id uuid, p_due_at timestamptz, p_reason text, p_promised_text text default null)
returns uuid language sql security definer set search_path = salesos_ai, pg_temp as $$
  insert into salesos_ai.followups (dealer_id, lead_id, kind, due_at, reason, promised_text, created_by_run_id)
  select r.dealer_id, r.lead_id, 'agent_promise', p_due_at, left(p_reason, 200), left(p_promised_text, 200), r.id from salesos_ai.agent_runs r where r.id = p_run_id and r.lead_id is not null
  returning id
$$;

create or replace function salesos_ai.agent_handoff(p_run_id uuid, p_reason text, p_summary text, p_urgency text default 'normal')
returns uuid language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare r salesos_ai.agent_runs; v_id uuid;
begin
  select * into r from salesos_ai.agent_runs where id = p_run_id;
  if r.id is null or r.lead_id is null then raise exception 'run % not found', p_run_id; end if;
  update salesos_ai.leads set force_human = true, updated_at = now() where id = r.lead_id;
  insert into salesos_ai.agent_inbox_items (dealer_id, lead_id, run_id, kind, priority, title, summary, payload)
  values (r.dealer_id, r.lead_id, r.id, case when p_reason = 'legal' then 'legal_threat' else 'handoff' end::salesos_ai.inbox_kind,
          case p_urgency when 'urgent' then 1 when 'low' then 3 else 2 end, 'Assistant handed off: ' || replace(p_reason, '_', ' '), left(p_summary, 500),
          jsonb_build_object('reason', p_reason, 'urgency', p_urgency))
  on conflict (lead_id, kind) where status = 'open' and lead_id is not null do nothing
  returning id into v_id;
  if v_id is null then
    select id into v_id from salesos_ai.agent_inbox_items where lead_id = r.lead_id and status = 'open'
       and kind = case when p_reason = 'legal' then 'legal_threat' else 'handoff' end::salesos_ai.inbox_kind;
  end if;
  return v_id;
end $$;

-- VIN lookups return any status (so the agent learns "sold"); browsing only shows available / in_transit.
create or replace function salesos_ai.agent_search_inventory(p_dealer_id uuid, p_filters jsonb)
returns table (vin text, year int, make text, model text, "trim" text, condition text, mileage int, status text, price_cents bigint, msrp_cents bigint, exterior_color text)
language sql stable security definer set search_path = salesos_ai, pg_temp as $$
  select v.vin, v.year, v.make, v.model, v.trim, v.condition, v.mileage, v.status, v.price_cents, v.msrp_cents, v.exterior_color
    from salesos_ai.vehicles v
   where v.dealer_id = p_dealer_id
     and (case when p_filters ? 'vin' then upper(v.vin) = upper(p_filters->>'vin') else v.status in ('available','in_transit') end)
     and (p_filters->>'make' is null or v.make ilike p_filters->>'make')
     and (p_filters->>'model' is null or v.model ilike '%' || (p_filters->>'model') || '%')
     and (p_filters->>'year_min' is null or v.year >= (p_filters->>'year_min')::int)
     and (p_filters->>'year_max' is null or v.year <= (p_filters->>'year_max')::int)
     and (p_filters->>'max_price_cents' is null or v.price_cents <= (p_filters->>'max_price_cents')::bigint)
     and (p_filters->>'body_style' is null or v.body_style ilike p_filters->>'body_style')
     and (p_filters->>'condition' is null or v.condition = p_filters->>'condition')
   order by v.price_cents nulls last, v.year desc
   limit least(greatest(coalesce((p_filters->>'limit')::int, 3), 1), 5)
$$;

-- Only ever creates a 'requested' appointment (a rep confirms). Store hours 09:00-19:00 local, at least 30 min ahead.
create or replace function salesos_ai.agent_book_test_drive(p_run_id uuid, p_vin text, p_starts_at timestamptz, p_duration_min int default 30,
  p_notes text default null, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare r salesos_ai.agent_runs; v salesos_ai.vehicles; v_tz text; v_local timestamp; v_id uuid;
begin
  select * into r from salesos_ai.agent_runs where id = p_run_id;
  if r.id is null or r.lead_id is null then raise exception 'run % not found', p_run_id; end if;
  select timezone into v_tz from salesos_ai.dealers where id = r.dealer_id;
  select * into v from salesos_ai.vehicles where dealer_id = r.dealer_id and upper(vin) = upper(p_vin);
  if v.id is null or v.status not in ('available','in_transit') then
    return jsonb_build_object('status', 'unavailable', 'reason', 'That vehicle is not available for a test drive.', 'alternatives', '[]'::jsonb);
  end if;
  v_local := p_starts_at at time zone v_tz;
  if p_starts_at < p_now + interval '30 minutes' or v_local::time < '09:00' or (v_local + make_interval(mins => p_duration_min))::time > '19:00' then
    return jsonb_build_object('status', 'unavailable', 'reason', 'Test drives run 9am-7pm store time, at least 30 minutes ahead.',
      'alternatives', jsonb_build_array(to_char(((date_trunc('day', greatest(v_local, (p_now at time zone v_tz)) + interval '1 day') + interval '10 hours') at time zone v_tz) at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"')));
  end if;
  insert into salesos_ai.appointments (dealer_id, lead_id, vehicle_id, kind, starts_at, duration_min, status, created_by_run_id)
  values (r.dealer_id, r.lead_id, v.id, 'test_drive', p_starts_at, p_duration_min, 'requested', r.id) returning id into v_id;
  return jsonb_build_object('status', 'requested', 'appointment_id', v_id);
end $$;

create or replace function salesos_ai.agent_request_appraisal(p_run_id uuid, p jsonb)
returns uuid language sql security definer set search_path = salesos_ai, pg_temp as $$
  insert into salesos_ai.trade_in_appraisals (dealer_id, lead_id, year, make, model, trim, mileage, vin, condition, has_lien, created_by_run_id)
  select r.dealer_id, r.lead_id, (p->>'year')::int, p->>'make', p->>'model', p->>'trim', (p->>'mileage')::int, upper(p->>'vin'), p->>'condition', (p->>'has_lien')::boolean, r.id
    from salesos_ai.agent_runs r where r.id = p_run_id and r.lead_id is not null
  returning id
$$;

create table if not exists salesos_ai.prequal_links (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references salesos_ai.dealers(id) on delete cascade,
  lead_id uuid not null references salesos_ai.leads(id) on delete cascade,
  token_hash text not null unique,                            -- sha256(token); the token itself only lives in the link
  params jsonb not null default '{}'::jsonb,
  expires_at timestamptz not null,
  used_at timestamptz,
  created_at timestamptz not null default now()
);
create or replace function salesos_ai.create_prequal_link(p_run_id uuid, p_params jsonb, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare r salesos_ai.agent_runs; v_token text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''); v_exp timestamptz := p_now + interval '72 hours';
begin
  select * into r from salesos_ai.agent_runs where id = p_run_id;
  if r.id is null or r.lead_id is null then raise exception 'run % not found', p_run_id; end if;
  insert into salesos_ai.prequal_links (dealer_id, lead_id, token_hash, params, expires_at, created_at)
  values (r.dealer_id, r.lead_id, encode(sha256(convert_to(v_token, 'UTF8')), 'hex'), coalesce(p_params, '{}'::jsonb), v_exp, p_now);
  return jsonb_build_object('token', v_token, 'expires_at', v_exp);
end $$;

-- =====================================================================================
-- PART Q. REP REVIEW, SWEEPER HELPERS, THREADED FINALIZE, ONE-CLICK UNSUBSCRIBE
-- =====================================================================================
-- A rep approves (optionally edits) a draft. It becomes the rep's message (actor human), is re-based on the thread the
-- rep just read (expected_context_version = now), and released immediately. The sweeper still re-runs the full chain and
-- can_send(commit): consent, DNC, quiet hours, caps and content gates apply to approved text too.
create or replace function salesos_ai.approve_draft(p_draft_id uuid, p_body text default null, p_actor uuid default null, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare d salesos_ai.outbound_drafts; v_actor uuid; v_cv int;
begin
  select * into d from salesos_ai.outbound_drafts where id = p_draft_id for update;
  if d.id is null then raise exception 'draft % not found', p_draft_id; end if;
  v_actor := salesos_ai.require_staff(d.dealer_id, p_actor);
  if d.status not in ('awaiting_review','held','delayed','handed_to_rep','stale') then
    raise exception 'draft % is %, it cannot be approved', p_draft_id, d.status using errcode = '22023';
  end if;
  if p_body is not null and length(btrim(p_body)) = 0 then raise exception 'invalid: empty body' using errcode = '22023'; end if;
  select context_version into v_cv from salesos_ai.leads where id = d.lead_id;
  update salesos_ai.outbound_drafts set status = 'held', actor = 'human', release_at = p_now, approved_by = v_actor, approved_at = p_now,
         body_edited = coalesce(nullif(btrim(p_body), ''), body_edited), expected_context_version = coalesce(v_cv, expected_context_version), updated_at = p_now
   where id = d.id;
  update salesos_ai.agent_inbox_items set status = 'resolved', resolved_at = p_now, resolved_by = v_actor
   where draft_id = d.id and status = 'open';
  perform salesos_ai.kick_outbound_sweeper();
  return jsonb_build_object('draft_id', d.id, 'status', 'held', 'release_at', p_now);
end $$;

create or replace function salesos_ai.discard_draft(p_draft_id uuid, p_actor uuid default null, p_now timestamptz default now())
returns void language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare d salesos_ai.outbound_drafts; v_actor uuid;
begin
  select * into d from salesos_ai.outbound_drafts where id = p_draft_id for update;
  if d.id is null then raise exception 'draft % not found', p_draft_id; end if;
  v_actor := salesos_ai.require_staff(d.dealer_id, p_actor);
  if d.status in ('sending','sent') then raise exception 'draft % is %, too late to discard', p_draft_id, d.status using errcode = '22023'; end if;
  update salesos_ai.outbound_drafts set status = 'discarded', veto_code = 'discarded_by_rep', updated_at = p_now where id = d.id;
end $$;

create or replace function salesos_ai.sweeper_release_facts(p_draft_id uuid)
returns jsonb language sql stable security definer set search_path = salesos_ai, pg_temp as $$
  select jsonb_build_object(
    'lead_context_version', l.context_version, 'force_human', coalesce(l.force_human, false) or coalesce(l.bot_silenced_until > now(), false),
    'open_inbox', exists (select 1 from salesos_ai.agent_inbox_items i where i.lead_id = d.lead_id and i.status = 'open'),
    'auto_send_enabled', s.auto_send_enabled, 'handoff_hours', s.followup_handoff_hours, 'approved', d.approved_at is not null)
    from salesos_ai.outbound_drafts d join salesos_ai.dealer_settings s on s.dealer_id = d.dealer_id left join salesos_ai.leads l on l.id = d.lead_id
   where d.id = p_draft_id
$$;

create or replace function salesos_ai.set_draft_status(p_draft_id uuid, p_status text, p_set_release boolean default false, p_release_at timestamptz default null,
  p_veto_code text default null, p_reservation_id uuid default null, p_body text default null, p_now timestamptz default now())
returns void language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
begin
  if p_status not in ('held','delayed','vetoed','handed_to_rep','awaiting_review','sending','failed') then
    raise exception 'invalid draft status %', p_status using errcode = '22023';
  end if;
  update salesos_ai.outbound_drafts set status = p_status,
         release_at = case when p_set_release then p_release_at else release_at end,
         veto_code = coalesce(left(p_veto_code, 120), veto_code), reservation_id = coalesce(p_reservation_id, reservation_id),
         body_edited = coalesce(p_body, body_edited), updated_at = p_now
   where id = p_draft_id;
  if p_status = 'handed_to_rep' then
    insert into salesos_ai.agent_inbox_items (dealer_id, lead_id, draft_id, kind, priority, title, summary, payload)
    select d.dealer_id, d.lead_id, d.id, 'needs_review', 2, 'Draft needs a person', 'The assistant''s draft was not sent automatically (' || coalesce(p_veto_code, 'review') || ').',
           jsonb_build_object('draft_id', d.id, 'code', p_veto_code)
      from salesos_ai.outbound_drafts d where d.id = p_draft_id and d.lead_id is not null
    on conflict (lead_id, kind) where status = 'open' and lead_id is not null do nothing;
  end if;
end $$;

create or replace function salesos_ai.followup_facts(p_plan_id uuid)
returns jsonb language sql stable security definer set search_path = salesos_ai, pg_temp as $$
  select jsonb_build_object('first_name', c.first_name,
    'vehicle', (select jsonb_build_object('vin', v.vin, 'status', v.status, 'price_cents', v.price_cents, 'msrp_cents', v.msrp_cents, 'year', v.year, 'make', v.make, 'model', v.model)
                  from salesos_ai.vehicles v where v.id = coalesce(p.vehicle_id, (p.context->>'vehicle_id')::uuid) and v.dealer_id = p.dealer_id))
    from salesos_ai.followup_plans p join salesos_ai.contacts c on c.id = p.contact_id where p.id = p_plan_id
$$;

-- Replaces the phase-3 version: same contract, plus conversation threading and the 'sent' status the receipts advance.
create or replace function salesos_ai.finalize_draft_send(p_draft_id uuid, p_ok boolean, p_provider_message_id text default null,
  p_error text default null, p_body text default null, p_now timestamptz default now())
returns uuid language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare d salesos_ai.outbound_drafts; v_msg uuid; v_conv uuid;
begin
  select * into d from salesos_ai.outbound_drafts where id = p_draft_id for update;
  if d.id is null then raise exception 'draft % not found', p_draft_id; end if;
  if d.status <> 'sending' then raise exception 'draft % is %, not sending', p_draft_id, d.status; end if;
  if p_ok then
    insert into salesos_ai.conversations as cv (dealer_id, contact_id, number_id, channel, lead_id, last_message_at)
    values (d.dealer_id, d.contact_id, d.number_id, d.channel, d.lead_id, p_now)
    on conflict (dealer_id, contact_id, number_id) do update set last_message_at = greatest(cv.last_message_at, excluded.last_message_at), lead_id = coalesce(excluded.lead_id, cv.lead_id)
    returning id into v_conv;
    insert into salesos_ai.messages (dealer_id, lead_id, contact_id, number_id, conversation_id, channel, direction, author_kind, body, provider_message_id, status, created_at)
    values (d.dealer_id, d.lead_id, d.contact_id, d.number_id, v_conv, d.channel, 'outbound', d.actor, coalesce(p_body, d.body_edited, d.body_ai), p_provider_message_id, 'sent', p_now)
    returning id into v_msg;
    if d.reservation_id is not null then perform salesos_ai.confirm_send(d.reservation_id, v_msg, p_now); end if;
    update salesos_ai.outbound_drafts set status = 'sent', message_id = v_msg, updated_at = p_now where id = d.id;
    update salesos_ai.followup_plans set status = 'sent', finished_at = p_now, updated_at = p_now where draft_id = d.id and status = 'drafted';
  else
    if d.reservation_id is not null then perform salesos_ai.release_send(d.reservation_id, left(p_error, 200)); end if;
    update salesos_ai.outbound_drafts set status = 'failed', veto_code = left(coalesce(p_error, 'provider_error'), 120), updated_at = p_now where id = d.id;
    if d.lead_id is not null then
      insert into salesos_ai.agent_inbox_items (dealer_id, lead_id, draft_id, kind, priority, title, summary, payload)
      values (d.dealer_id, d.lead_id, d.id, 'send_failed', 2, 'Message not delivered to the provider', left(coalesce(p_error, 'provider_error'), 200), jsonb_build_object('draft_id', d.id))
      on conflict (lead_id, kind) where status = 'open' and lead_id is not null do nothing;
    end if;
  end if;
  return v_msg;
end $$;

-- ---------- one-click unsubscribe (RFC 8058) ----------
create table if not exists salesos_ai.unsubscribe_tokens (
  token_hash text primary key,                                -- sha256(token); never expires (CAN-SPAM: honor for 30+ days)
  dealer_id uuid not null references salesos_ai.dealers(id) on delete cascade,
  contact_id uuid not null references salesos_ai.contacts(id) on delete cascade,
  channel salesos_ai.channel_kind not null default 'email',
  message_id uuid references salesos_ai.messages(id) on delete set null,
  created_at timestamptz not null default now(),
  redeemed_at timestamptz
);
create index if not exists unsubscribe_tokens_contact_idx on salesos_ai.unsubscribe_tokens (contact_id);

create or replace function salesos_ai.create_unsubscribe_token(p_dealer_id uuid, p_contact_id uuid, p_channel salesos_ai.channel_kind default 'email')
returns text language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare v_token text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
begin
  if not exists (select 1 from salesos_ai.contacts where id = p_contact_id and dealer_id = p_dealer_id) then raise exception 'contact not found'; end if;
  insert into salesos_ai.unsubscribe_tokens (token_hash, dealer_id, contact_id, channel) values (encode(sha256(convert_to(v_token, 'UTF8')), 'hex'), p_dealer_id, p_contact_id, p_channel);
  return v_token;
end $$;

-- Idempotent: a second click (or the mail client's POST plus the person's GET) records nothing new.
create or replace function salesos_ai.redeem_unsubscribe_token(p_token text, p_method text default 'one_click_post', p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare t salesos_ai.unsubscribe_tokens; v_ce uuid; v_name text;
begin
  select * into t from salesos_ai.unsubscribe_tokens where token_hash = encode(sha256(convert_to(coalesce(p_token, ''), 'UTF8')), 'hex') for update;
  if t.token_hash is null then return jsonb_build_object('ok', false, 'error', 'unknown_token'); end if;
  select name into v_name from salesos_ai.dealers where id = t.dealer_id;
  if t.redeemed_at is null then
    if not exists (select 1 from salesos_ai.contact_dnc x where x.contact_id = t.contact_id and x.cleared_at is null and (x.channel is null or x.channel = t.channel)) then
      v_ce := salesos_ai.record_opt_out(t.dealer_id, t.contact_id, t.channel, 'inbound_message', jsonb_build_object('method', p_method), 'email unsubscribe link');
    end if;
    update salesos_ai.unsubscribe_tokens set redeemed_at = p_now where token_hash = t.token_hash;
  end if;
  return jsonb_build_object('ok', true, 'dealer_name', v_name, 'already', t.redeemed_at is not null, 'consent_event_id', v_ce);
end $$;

-- =====================================================================================
-- PART R. KICKERS, SCHEDULE, PRUNING, RLS, GRANTS
-- =====================================================================================
create or replace function salesos_ai.kick_agent_runner() returns void language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
begin
  if exists (select 1 from salesos_ai.agent_jobs where status = 'queued' and not_before <= now())
     or exists (select 1 from salesos_ai.agent_jobs where status = 'running' and locked_at < now() - interval '5 minutes') then
    perform salesos_ai.invoke_edge_function('agent-runner');
  end if;
end $$;

create or replace function salesos_ai.kick_classify_worker() returns void language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
begin
  if exists (select 1 from salesos_ai.classify_queue where not_before <= now() and attempts < 5 and (locked_at is null or locked_at < now() - interval '5 minutes')) then
    perform salesos_ai.invoke_edge_function('classify-worker');
  end if;
end $$;

create or replace function salesos_ai.kick_template_sync() returns void language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
begin
  if exists (select 1 from salesos_ai.channel_numbers where provider = 'meta_cloud' and status in ('active','paused')) then
    perform salesos_ai.invoke_edge_function('whatsapp-template-sync');
  end if;
end $$;

create or replace function salesos_ai.prune_runtime(p_now timestamptz default now())
returns void language sql security definer set search_path = salesos_ai, pg_temp as $$
  delete from salesos_ai.event_log where received_at < p_now - interval '30 days';
  delete from salesos_ai.agent_jobs where status in ('done','skipped','escalated','dead') and updated_at < p_now - interval '30 days';
  delete from salesos_ai.send_attempts where status in ('sent','failed') and started_at < p_now - interval '45 days';
  delete from salesos_ai.prequal_links where expires_at < p_now - interval '30 days';
$$;

do $cron$
begin
  if to_regclass('cron.job') is null then raise notice 'pg_cron not available; phase-4 schedules skipped'; return; end if;
  perform cron.schedule('salesos-agent-runner',  '15 seconds',  $$select salesos_ai.kick_agent_runner()$$);
  perform cron.schedule('salesos-classify',      '30 seconds',  $$select salesos_ai.kick_classify_worker()$$);
  perform cron.schedule('salesos-template-sync', '17 * * * *',  $$select salesos_ai.kick_template_sync()$$);
  perform cron.schedule('salesos-runtime-prune', '45 3 * * *',  $$select salesos_ai.prune_runtime()$$);
exception when others then
  raise notice 'pg_cron scheduling skipped: %', sqlerrm;
end
$cron$;

do $rls$
declare t text;
begin
  -- staff-visible
  foreach t in array array['conversations','message_templates'] loop
    execute format('alter table salesos_ai.%I enable row level security', t);
    execute format('drop policy if exists %I on salesos_ai.%I', t || '_member_select', t);
    execute format('create policy %I on salesos_ai.%I for select to authenticated using (salesos_ai.is_dealer_member(dealer_id))', t || '_member_select', t);
    execute format('revoke all on salesos_ai.%I from anon, authenticated', t);
    execute format('grant select on salesos_ai.%I to authenticated', t);
  end loop;
  -- plumbing: service role only (raw payloads, token hashes, job state)
  foreach t in array array['send_attempts','event_log','agent_jobs','classify_queue','keyword_replies','unsubscribe_tokens','prequal_links'] loop
    execute format('alter table salesos_ai.%I enable row level security', t);
    execute format('revoke all on salesos_ai.%I from anon, authenticated', t);
  end loop;
end
$rls$;

do $grants$
declare r record;
begin
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'salesos_ai' and p.proname = any (array[
              'claim_send_attempt','complete_send_attempt','get_send_target','message_status_rank','apply_message_status',
              'upsert_message_templates','apply_template_status','list_template_numbers','pick_whatsapp_template','log_webhook_event','finish_webhook_event',
              'resolve_inbound_number','enqueue_agent_job','ingest_inbound_message','apply_inbound_keyword','record_system_message',
              'claim_classification_jobs','finish_classification_job','claim_agent_jobs','start_agent_run','finish_agent_run','finish_agent_job',
              'get_agent_turn_context','agent_record_draft','insert_before_send_traces','agent_record_tool_call','agent_schedule_followup',
              'agent_handoff','agent_search_inventory','agent_book_test_drive','agent_request_appraisal','create_prequal_link',
              'sweeper_release_facts','set_draft_status','followup_facts','create_unsubscribe_token','redeem_unsubscribe_token',
              'kick_agent_runner','kick_classify_worker','kick_template_sync','prune_runtime',
              -- phase-1 helpers the workers call directly
              'can_send','record_opt_out','ai_budget_reserve','ai_budget_settle','agent_breaker_open','claim_due_drafts','apply_lead_stage',
              'confirm_send','release_send','record_draft_citations','record_classification','record_classification_failure','finalize_draft_send'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'salesos_ai' and p.proname = any (array['approve_draft','discard_draft'])
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated, service_role', r.sig);
  end loop;
end
$grants$;
