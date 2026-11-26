-- =====================================================================================
-- SalesOS: consent ledger + can_send() gate  |  guardrailed agent  |  Morning Drive briefing
-- Postgres 15+ (tested on 17). Idempotent: safe to run twice.
--
-- Pattern attributions (ideas only; all code here is original). Upstream repos are MIT:
--   * DeskcommCRM (melgarafael/DeskcommCRM, MIT): warm-up ladder + throttle/jitter + separate reply window,
--     anti-template ("spinning") check, per-number advisory lock, ordered before_send gates + traces,
--     per-org AI spend cap, frozen facts-only daily report, agent_inbox_items hand-off queue.
--   * AgentSDR (Kandid-ai/AgentSDR, MIT): draft -> hold -> auto-send verdicts, 48h hand-to-rep,
--     forward-only stage policy, DNC row with a CHECK on provenance, draft citations.
--   * AgenticCRM (Sapheron/AgenticCRM, MIT): per-tenant circuit breaker, daily lead-decay with half-life.
--   * wacrm (ArnasDon/wacrm, MIT): atomic per-conversation AI reply cap, 24h WhatsApp service window.
--
-- Assumes Supabase (roles anon/authenticated/service_role, auth.uid()). Minimal versions of your
-- core tables are created IF NOT EXISTS and then ALTERed with the columns this file needs.
-- Not legal advice: quiet-hour/state tables are a starting point to verify with counsel.
-- =====================================================================================

-- ---------- enums ----------
do $$ begin create type public.channel_kind    as enum ('sms','whatsapp','email');                         exception when duplicate_object then null; end $$;
do $$ begin create type public.consent_purpose as enum ('transactional','conversational','marketing');     exception when duplicate_object then null; end $$;
do $$ begin create type public.consent_action  as enum ('grant','revoke');                                 exception when duplicate_object then null; end $$;
do $$ begin create type public.consent_source  as enum ('web_form','sms_keyword','inbound_message','esign','verbal_recorded','in_person_form','dms_import','import','staff_entry','api'); exception when duplicate_object then null; end $$;
do $$ begin create type public.send_kind       as enum ('reply','followup','cold','transactional');        exception when duplicate_object then null; end $$;
do $$ begin create type public.send_verdict    as enum ('allow','delay','veto');                           exception when duplicate_object then null; end $$;
do $$ begin create type public.briefing_item_kind as enum ('waiting_reply','test_drive_today','test_drive_noshow','hot_gone_quiet','callback_due','price_drop_viewed','trade_in_pending','lease_ending'); exception when duplicate_object then null; end $$;

do $$ begin
  create type public.send_decision as (
    verdict        public.send_verdict,
    code           text,
    reason         text,
    not_before     timestamptz,
    reservation_id uuid,
    details        jsonb
  );
exception when duplicate_object then null; end $$;

-- ---------- core tables (minimal; skipped if you already have them) ----------
create table if not exists public.dealers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  timezone text not null default 'America/New_York',
  state_code char(2),
  created_at timestamptz not null default now()
);
create table if not exists public.dealer_members (
  user_id uuid not null,
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  role text not null default 'sales',          -- owner | admin | manager | sales | bdc | viewer
  primary key (user_id, dealer_id)
);
create table if not exists public.contacts (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  first_name text, last_name text,
  phone_e164 text, email text,
  created_at timestamptz not null default now()
);
create table if not exists public.vehicles (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  vin text not null,
  created_at timestamptz not null default now()
);
create table if not exists public.leads (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  contact_id uuid not null references public.contacts(id) on delete cascade,
  created_at timestamptz not null default now()
);

-- columns this file relies on (no-ops if present)
alter table public.dealers  add column if not exists timezone text not null default 'America/New_York';
alter table public.dealers  add column if not exists state_code char(2);
alter table public.dealer_members add column if not exists briefing_enabled boolean not null default true;
alter table public.contacts add column if not exists timezone text;                 -- IANA, e.g. America/Chicago; null = dealer tz
alter table public.contacts add column if not exists state_code char(2);            -- recipient's state (for stricter state quiet hours)
alter table public.contacts add column if not exists is_anonymized boolean not null default false;
alter table public.vehicles add column if not exists year int;
alter table public.vehicles add column if not exists make text;
alter table public.vehicles add column if not exists model text;
alter table public.vehicles add column if not exists trim text;
alter table public.vehicles add column if not exists price_cents bigint;
alter table public.vehicles add column if not exists msrp_cents bigint;
alter table public.vehicles add column if not exists status text not null default 'available';  -- available|pending|sold|hold|in_transit
alter table public.vehicles add column if not exists updated_at timestamptz not null default now();
alter table public.leads    add column if not exists assigned_to uuid;
alter table public.leads    add column if not exists stage text not null default 'new';
alter table public.leads    add column if not exists vehicle_id uuid references public.vehicles(id) on delete set null;
alter table public.leads    add column if not exists value_cents bigint;
alter table public.leads    add column if not exists lease_end_on date;
alter table public.leads    add column if not exists last_inbound_at timestamptz;
alter table public.leads    add column if not exists last_outbound_at timestamptz;
alter table public.leads    add column if not exists force_human boolean not null default false;
alter table public.leads    add column if not exists bot_silenced_until timestamptz;
alter table public.leads    add column if not exists context_version int not null default 0;
alter table public.leads    add column if not exists updated_at timestamptz not null default now();

create unique index if not exists vehicles_dealer_vin_uq on public.vehicles (dealer_id, vin);
create index if not exists leads_dealer_assigned_idx on public.leads (dealer_id, assigned_to) where stage not in ('won','lost');
create index if not exists leads_waiting_idx on public.leads (dealer_id, last_inbound_at) where stage not in ('won','lost');

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  lead_id uuid references public.leads(id) on delete cascade,
  contact_id uuid not null references public.contacts(id) on delete cascade,
  number_id uuid,                                  -- channel_numbers.id (fk added below)
  channel public.channel_kind not null,
  direction text not null check (direction in ('inbound','outbound')),
  author_kind text not null default 'contact' check (author_kind in ('contact','ai','human','system')),
  body text,
  provider_message_id text,
  status text not null default 'received',
  created_at timestamptz not null default now()
);
create index if not exists messages_contact_chan_dir_idx on public.messages (contact_id, channel, direction, created_at desc);
create index if not exists messages_lead_created_idx on public.messages (lead_id, created_at desc);

create table if not exists public.appointments (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  lead_id uuid not null references public.leads(id) on delete cascade,
  vehicle_id uuid references public.vehicles(id) on delete set null,
  kind text not null default 'test_drive' check (kind in ('test_drive','showroom','appraisal','delivery','service')),
  starts_at timestamptz not null,
  duration_min int not null default 30,
  status text not null default 'requested' check (status in ('requested','confirmed','completed','no_show','cancelled')),
  created_by_run_id uuid,
  created_at timestamptz not null default now()
);
create index if not exists appointments_dealer_starts_idx on public.appointments (dealer_id, starts_at);

create table if not exists public.trade_in_appraisals (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  lead_id uuid not null references public.leads(id) on delete cascade,
  year int, make text, model text, trim text, mileage int, vin text,
  condition text check (condition in ('excellent','good','fair','poor')),
  has_lien boolean,
  status text not null default 'requested' check (status in ('requested','in_review','offered','declined','expired')),
  offer_cents bigint,
  created_by_run_id uuid,
  requested_at timestamptz not null default now()
);
create index if not exists trade_in_pending_idx on public.trade_in_appraisals (dealer_id, requested_at) where status in ('requested','in_review');

create table if not exists public.followups (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  lead_id uuid not null references public.leads(id) on delete cascade,
  assigned_to uuid,
  kind text not null default 'agent_promise' check (kind in ('agent_promise','rep_callback','sequence','stalled')),
  due_at timestamptz not null,
  reason text,
  promised_text text,
  status text not null default 'scheduled' check (status in ('scheduled','due','done','cancelled')),
  created_by_run_id uuid,
  created_at timestamptz not null default now()
);
create index if not exists followups_due_idx on public.followups (dealer_id, due_at) where status in ('scheduled','due');

create table if not exists public.vehicle_price_events (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  vehicle_id uuid not null references public.vehicles(id) on delete cascade,
  old_price_cents bigint not null, new_price_cents bigint not null,
  changed_at timestamptz not null default now()
);
create index if not exists vehicle_price_events_idx on public.vehicle_price_events (vehicle_id, changed_at desc);

create table if not exists public.lead_vehicle_views (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  lead_id uuid not null references public.leads(id) on delete cascade,
  vehicle_id uuid not null references public.vehicles(id) on delete cascade,
  viewed_at timestamptz not null default now()
);
create index if not exists lead_vehicle_views_idx on public.lead_vehicle_views (vehicle_id, viewed_at desc);
create index if not exists lead_vehicle_views_lead_idx on public.lead_vehicle_views (lead_id, viewed_at desc);

create table if not exists public.lead_activities (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  lead_id uuid not null references public.leads(id) on delete cascade,
  actor_kind text not null check (actor_kind in ('ai','human','system')),
  actor_id uuid,
  kind text not null,                               -- stage_changed | stage_change_proposed | note | ...
  from_stage text, to_stage text,
  confidence numeric(5,4) check (confidence is null or (confidence between 0 and 1)),
  reason text,
  evidence jsonb not null default '{}'::jsonb,      -- e.g. {"quote":"can I come Saturday?","run_id":"..."}
  created_at timestamptz not null default now()
);
create index if not exists lead_activities_lead_idx on public.lead_activities (lead_id, created_at desc);

-- ---------- RLS helper ----------
create or replace function public.is_dealer_member(p_dealer_id uuid, p_roles text[] default null)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.dealer_members m
    where m.user_id = auth.uid() and m.dealer_id = p_dealer_id
      and (p_roles is null or m.role::text = any (p_roles))
  )
$$;

-- =====================================================================================
-- PART A. CONSENT LEDGER + can_send()
-- =====================================================================================

-- ---------- per-dealer settings (defaults documented in SPEC.md) ----------
create table if not exists public.dealer_settings (
  dealer_id uuid primary key references public.dealers(id) on delete cascade,
  -- compliance
  quiet_start time not null default '08:00',                 -- TCPA: no telemarketing before 8am local (called party)
  quiet_end   time not null default '21:00',                 --        or after 9pm local
  sunday_start time,                                         -- optional later Sunday opening
  reply_ignores_quiet boolean not null default true,         -- answering someone who just texted us
  transactional_ignores_quiet boolean not null default false,
  reply_window_hours int not null default 24 check (reply_window_hours between 1 and 168),
  email_requires_consent boolean not null default true,
  ai_disclosure_text text not null default 'You''re chatting with {dealer}''s virtual assistant. A team member can step in anytime.',
  stop_footer_text text not null default 'Reply STOP to opt out, HELP for help. Msg & data rates may apply.',
  -- agent
  rep_hold_minutes int not null default 15 check (rep_hold_minutes between 0 and 1440),
  followup_hold_minutes int not null default 0 check (followup_hold_minutes between 0 and 1440),
  auto_send_enabled boolean not null default false,          -- consent-first: nothing auto-sends until a dealer opts in
  auto_send_kinds public.send_kind[] not null default '{reply,followup,transactional}',
  followup_handoff_hours int not null default 48 check (followup_handoff_hours >= 1),
  ai_max_unanswered_replies int not null default 3 check (ai_max_unanswered_replies between 1 and 20),
  -- briefing
  briefing_enabled boolean not null default true,
  briefing_local_time time not null default '06:30',
  briefing_days int[] not null default '{1,2,3,4,5,6}',      -- ISO dow, 1=Mon..7=Sun
  briefing_size int not null default 7 check (briefing_size between 1 and 20),
  updated_at timestamptz not null default now()
);

create or replace function public.dealers_seed_settings() returns trigger language plpgsql as $$
begin
  insert into public.dealer_settings(dealer_id) values (new.id) on conflict do nothing;
  insert into public.ai_budgets(dealer_id) values (new.id) on conflict do nothing;
  return new;
end $$;

-- ---------- stricter state quiet hours (starting point; verify with counsel) ----------
create table if not exists public.state_quiet_hours (
  state_code char(2) primary key,
  start_time time not null,
  end_time time not null,
  sunday_start time,
  note text
);
insert into public.state_quiet_hours(state_code, start_time, end_time, sunday_start, note) values
  ('FL','08:00','20:00',null,   'Florida Telephone Solicitation Act (FTSA): 8am-8pm'),
  ('OK','08:00','20:00',null,   'Oklahoma Telephone Solicitation Act: 8am-8pm'),
  ('MD','08:00','20:00',null,   'Maryland Stop the Spam Calls Act: 8am-8pm'),
  ('WA','08:00','20:00',null,   'Washington telephone solicitation: 8am-8pm'),
  ('TX','09:00','21:00','12:00','Texas: 9am-9pm Mon-Sat, noon-9pm Sunday')
on conflict (state_code) do nothing;

-- ---------- sending identities: SMS numbers, WhatsApp numbers, email mailboxes ----------
create table if not exists public.channel_numbers (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  channel public.channel_kind not null,
  provider text not null default 'twilio',                   -- twilio | meta_cloud | postmark | ...  (prefer official APIs)
  address text not null,                                     -- E.164 number or mailbox
  status text not null default 'active' check (status in ('active','paused','banned','pending')),
  activated_at timestamptz,                                  -- null => treated as age 0 (strictest warm-up step)
  warmup_enabled boolean not null default true,              -- false for registered/verified senders with carrier-assigned throughput
  warmup_steps jsonb not null default '[{"min_age_days":0,"cap":20},{"min_age_days":4,"cap":50},{"min_age_days":8,"cap":100},{"min_age_days":15,"cap":200},{"min_age_days":31,"cap":null}]',
  daily_cap_override int check (daily_cap_override is null or daily_cap_override > 0), -- e.g. 10DLC throughput or WA messaging tier
  throttle_ms int not null default 1200 check (throttle_ms >= 0),
  jitter_max_ms int not null default 800 check (jitter_max_ms >= 0),
  next_allowed_at timestamptz,                               -- reservation cursor: next send slot for this identity
  spin_window int not null default 20,
  spin_threshold numeric not null default 0.8 check (spin_threshold between 0 and 1),
  spin_repetition int not null default 2,                    -- 2 near-identical copies in window => the 3rd is vetoed
  spin_allow_max_len int not null default 15,
  spin_allow_regex text not null default 'https?://\S*(pay|checkout|book|schedule|appointment|prequal|calendly)',
  created_at timestamptz not null default now(),
  unique (dealer_id, channel, address)
);
do $$ begin
  alter table public.messages add constraint messages_number_fk foreign key (number_id) references public.channel_numbers(id) on delete set null;
exception when duplicate_object then null; end $$;

-- ---------- consent ledger (append-only) ----------
create table if not exists public.consent_events (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  contact_id uuid not null references public.contacts(id) on delete cascade,
  channel public.channel_kind,                               -- null only for an all-channel revoke
  purpose public.consent_purpose,                            -- null on revoke = every purpose
  action public.consent_action not null,
  source public.consent_source not null,
  evidence jsonb not null default '{}'::jsonb,               -- {proof_uri, form_url, message_id, ip, user_agent, recording_id ...}
  disclosure_text_version text,                              -- id/hash of the exact disclosure shown (required for marketing grants)
  actor_user_id uuid,
  note text,
  created_at timestamptz not null default now(),
  constraint consent_grant_needs_channel check (action = 'revoke' or (channel is not null and purpose is not null))
);
create index if not exists consent_events_contact_idx on public.consent_events (contact_id, created_at desc);
create index if not exists consent_events_dealer_idx on public.consent_events (dealer_id, created_at desc);

create or replace function public.consent_events_append_only() returns trigger language plpgsql as $$
begin
  raise exception 'consent_events is append-only (% blocked)', tg_op using errcode = 'restrict_violation';
end $$;
drop trigger if exists consent_events_no_update on public.consent_events;
create trigger consent_events_no_update before update or delete on public.consent_events
  for each row execute function public.consent_events_append_only();

-- derived state: what is currently granted/revoked per contact+channel+purpose
create table if not exists public.contact_consent_state (
  contact_id uuid not null references public.contacts(id) on delete cascade,
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  channel public.channel_kind not null,
  purpose public.consent_purpose not null,
  status text not null check (status in ('granted','revoked')),
  evidence_ok boolean not null default false,                -- grant counts only with provenance (see trigger)
  since timestamptz not null default now(),
  last_event_id uuid references public.consent_events(id),
  primary key (contact_id, channel, purpose)
);
create index if not exists contact_consent_state_dealer_idx on public.contact_consent_state (dealer_id);

-- Do-Not-Contact: one open row blocks the channel (channel null = every channel). Staff cannot clear it.
create table if not exists public.contact_dnc (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  contact_id uuid not null references public.contacts(id) on delete cascade,
  channel public.channel_kind,
  source public.consent_source not null,
  reason text,
  set_at timestamptz not null default now(),
  set_by_event uuid references public.consent_events(id),
  cleared_at timestamptz,
  cleared_by_event uuid references public.consent_events(id),
  constraint dnc_provenance check ((cleared_at is null) or (cleared_by_event is not null))
);
create unique index if not exists contact_dnc_open_chan_uq on public.contact_dnc (contact_id, channel) where cleared_at is null and channel is not null;
create unique index if not exists contact_dnc_open_all_uq  on public.contact_dnc (contact_id) where cleared_at is null and channel is null;
create index if not exists contact_dnc_lookup_idx on public.contact_dnc (contact_id) where cleared_at is null;

-- purpose hierarchy: marketing (express written) covers conversational covers transactional
create or replace function public.purpose_rank(p public.consent_purpose) returns int language sql immutable as $$
  select case p when 'transactional' then 1 when 'conversational' then 2 when 'marketing' then 3 end
$$;

create or replace function public.consent_events_apply() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_ok boolean;
  v_contact_initiated boolean;
begin
  if new.action = 'revoke' then
    if new.purpose is null then
      insert into public.contact_dnc (dealer_id, contact_id, channel, source, reason, set_at, set_by_event)
      select new.dealer_id, new.contact_id, new.channel, new.source, coalesce(new.note, 'opt-out'), new.created_at, new.id
      where not exists (select 1 from public.contact_dnc d
                         where d.contact_id = new.contact_id and d.cleared_at is null
                           and coalesce(d.channel::text,'*') = coalesce(new.channel::text,'*'));
      update public.contact_consent_state s
         set status = 'revoked', since = new.created_at, last_event_id = new.id
       where s.contact_id = new.contact_id and (new.channel is null or s.channel = new.channel);
    else
      insert into public.contact_consent_state (contact_id, dealer_id, channel, purpose, status, evidence_ok, since, last_event_id)
      select new.contact_id, new.dealer_id, c, new.purpose, 'revoked', false, new.created_at, new.id
        from unnest(case when new.channel is null then enum_range(null::public.channel_kind) else array[new.channel] end) c
      on conflict (contact_id, channel, purpose)
      do update set status = 'revoked', evidence_ok = false, since = excluded.since, last_event_id = excluded.last_event_id;
    end if;
    return new;
  end if;

  -- grant
  v_contact_initiated := new.source in ('sms_keyword','web_form','inbound_message','esign','in_person_form','verbal_recorded');
  if exists (select 1 from public.contact_dnc d where d.contact_id = new.contact_id and d.cleared_at is null and d.channel is null) then
    raise exception 'DNC_ACTIVE: contact % has an all-channel Do-Not-Contact; clear it through the DNC process', new.contact_id
      using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.contact_dnc d where d.contact_id = new.contact_id and d.cleared_at is null and d.channel = new.channel) then
    if not v_contact_initiated then
      raise exception 'DNC_ACTIVE: contact % opted out of %; only the contact can re-opt-in (source=% rejected)', new.contact_id, new.channel, new.source
        using errcode = 'check_violation';
    end if;
    update public.contact_dnc set cleared_at = new.created_at, cleared_by_event = new.id
     where contact_id = new.contact_id and channel = new.channel and cleared_at is null;
  end if;

  -- provenance: imports/staff/api grants only count with a proof artifact; marketing also needs the disclosure version
  v_ok := (v_contact_initiated or (new.evidence ? 'proof_uri'))
          and (new.purpose <> 'marketing' or new.disclosure_text_version is not null);

  insert into public.contact_consent_state (contact_id, dealer_id, channel, purpose, status, evidence_ok, since, last_event_id)
  values (new.contact_id, new.dealer_id, new.channel, new.purpose, 'granted', v_ok, new.created_at, new.id)
  on conflict (contact_id, channel, purpose)
  do update set status = 'granted', evidence_ok = excluded.evidence_ok, since = excluded.since, last_event_id = excluded.last_event_id;
  return new;
end $$;
drop trigger if exists consent_events_apply_trg on public.consent_events;
create trigger consent_events_apply_trg after insert on public.consent_events
  for each row execute function public.consent_events_apply();

-- ---------- send reservations: caps, throttle, anti-template memory, idempotency ----------
create table if not exists public.send_reservations (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  number_id uuid not null references public.channel_numbers(id) on delete cascade,
  contact_id uuid not null references public.contacts(id) on delete cascade,
  lead_id uuid references public.leads(id) on delete set null,
  channel public.channel_kind not null,
  purpose public.consent_purpose not null,
  kind public.send_kind not null,
  actor text not null default 'ai' check (actor in ('ai','human','system')),
  body_norm text,
  is_template boolean not null default false,
  idempotency_key text,
  status text not null default 'reserved' check (status in ('reserved','sent','released')),
  message_id uuid,
  reserved_at timestamptz not null default now(),
  sent_at timestamptz,
  released_reason text
);
create index if not exists send_reservations_number_idx on public.send_reservations (number_id, reserved_at desc);
create unique index if not exists send_reservations_idem_uq on public.send_reservations (dealer_id, idempotency_key) where idempotency_key is not null;

-- ---------- AI budget (checked BEFORE every model call; DeskcommCRM-style per-org cap) ----------
create table if not exists public.ai_budgets (
  dealer_id uuid primary key references public.dealers(id) on delete cascade,
  period_start date not null default (date_trunc('month', now()))::date,
  monthly_cap_cents bigint not null default 5000 check (monthly_cap_cents >= 0),   -- $50/month default; tune per plan
  spent_cents numeric(14,4) not null default 0,
  hard_stop boolean not null default true,
  updated_at timestamptz not null default now()
);

drop trigger if exists dealers_seed_settings_trg on public.dealers;
create trigger dealers_seed_settings_trg after insert on public.dealers
  for each row execute function public.dealers_seed_settings();
insert into public.dealer_settings(dealer_id) select id from public.dealers on conflict do nothing;
insert into public.ai_budgets(dealer_id) select id from public.dealers on conflict do nothing;

-- Reserve an estimate before calling the model. Rolls the monthly period lazily. Returns false => do not call the model.
create or replace function public.ai_budget_reserve(p_dealer_id uuid, p_estimate_cents numeric, p_now timestamptz default now())
returns boolean language plpgsql security definer set search_path = public, pg_temp as $$
declare v_month date := (date_trunc('month', p_now))::date; v_ok boolean;
begin
  update public.ai_budgets set period_start = v_month, spent_cents = 0, updated_at = p_now
   where dealer_id = p_dealer_id and period_start < v_month;
  update public.ai_budgets b
     set spent_cents = b.spent_cents + p_estimate_cents, updated_at = p_now
   where b.dealer_id = p_dealer_id
     and (not b.hard_stop or b.spent_cents + p_estimate_cents <= b.monthly_cap_cents)
  returning true into v_ok;
  return coalesce(v_ok, false);
end $$;

-- After the call: replace the estimate with the real cost (may exceed the cap by one call; that is accepted).
create or replace function public.ai_budget_settle(p_dealer_id uuid, p_estimate_cents numeric, p_actual_cents numeric)
returns void language sql security definer set search_path = public, pg_temp as $$
  update public.ai_budgets set spent_cents = greatest(0, spent_cents - p_estimate_cents + p_actual_cents), updated_at = now()
   where dealer_id = p_dealer_id
$$;

create or replace function public.ai_budget_status(p_dealer_id uuid)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('cap_cents', monthly_cap_cents, 'spent_cents', spent_cents, 'hard_stop', hard_stop,
                            'remaining_cents', greatest(0, monthly_cap_cents - spent_cents))
    from public.ai_budgets where dealer_id = p_dealer_id
$$;

-- ---------- pure helpers ----------
create or replace function public._decision(p_verdict public.send_verdict, p_code text, p_reason text,
                                            p_not_before timestamptz default null, p_reservation uuid default null,
                                            p_details jsonb default '{}'::jsonb)
returns public.send_decision language sql immutable as $$
  select row(p_verdict, p_code, p_reason, p_not_before, p_reservation, p_details)::public.send_decision
$$;

create or replace function public.normalize_copy(p text) returns text language sql immutable as $$
  select trim(regexp_replace(lower(coalesce(p, '')), '\s+', ' ', 'g'))
$$;

create or replace function public.copy_tokens(p text) returns text[] language sql immutable as $$
  select coalesce(array(select distinct t from unnest(regexp_split_to_array(public.normalize_copy(p), ' ')) t where t <> ''), '{}')
$$;

create or replace function public.jaccard(a text[], b text[]) returns numeric language sql immutable as $$
  select case
    when cardinality(a) = 0 and cardinality(b) = 0 then 1
    else (select count(*)::numeric from (select unnest(a) intersect select unnest(b)) i)
         / nullif((select count(*) from (select unnest(a) union select unnest(b)) u), 0)
  end
$$;

-- First instant >= p_after that falls inside [p_start, p_end) local time (Sunday may open later). IANA tz.
create or replace function public.next_window_open(p_after timestamptz, p_tz text, p_start time, p_end time, p_sun_start time default null)
returns timestamptz language plpgsql immutable as $$
declare d date := (p_after at time zone p_tz)::date; i int; s time; open_ts timestamptz; close_ts timestamptz;
begin
  for i in 0..8 loop
    s := case when extract(dow from d + i) = 0 and p_sun_start is not null then p_sun_start else p_start end;
    open_ts  := ((d + i) + s)       at time zone p_tz;
    close_ts := ((d + i) + p_end)   at time zone p_tz;
    if p_after >= open_ts and p_after < close_ts then return p_after; end if;
    if open_ts > p_after then return open_ts; end if;
  end loop;
  return p_after + interval '1 day';
end $$;

-- Daily warm-up cap for a number; null = unlimited (formed). Honors daily_cap_override via least().
create or replace function public.number_daily_cap(p_number_id uuid, p_now timestamptz default now())
returns int language plpgsql stable as $$
declare n public.channel_numbers; age_days int; step jsonb; v_cap int; v_warm int;
begin
  select * into n from public.channel_numbers where id = p_number_id;
  if not found then return 0; end if;
  if n.warmup_enabled then
    age_days := case when n.activated_at is null then 0 else greatest(0, floor(extract(epoch from (p_now - n.activated_at)) / 86400))::int end;
    select e into step from jsonb_array_elements(n.warmup_steps) e
     where (e->>'min_age_days')::int <= age_days order by (e->>'min_age_days')::int desc limit 1;
    v_warm := case when step is null then 0 when step->'cap' = 'null'::jsonb then null else (step->>'cap')::int end;
  end if;
  if v_warm is null and n.daily_cap_override is null then return null; end if;
  return least(coalesce(v_warm, n.daily_cap_override), coalesce(n.daily_cap_override, v_warm));
end $$;

-- ---------- can_send(): the one gate every outbound message passes ----------
-- Order: contact/number sanity -> human-owned (AI only) -> DNC -> consent / reply-window -> quiet hours
--        -> warm-up daily cap -> throttle+jitter -> anti-template.
-- p_commit=false is a dry run (no lock, no writes). p_commit=true takes pg_advisory_xact_lock(number) for the
-- read-then-reserve critical section and inserts a send_reservation; call confirm_send()/release_send() afterwards.
create or replace function public.can_send(
  p_dealer_id uuid, p_contact_id uuid, p_channel public.channel_kind,
  p_purpose public.consent_purpose, p_kind public.send_kind, p_number_id uuid,
  p_body text default null, p_lead_id uuid default null, p_actor text default 'ai',
  p_is_template boolean default false, p_commit boolean default false,
  p_idempotency_key text default null, p_now timestamptz default now()
) returns public.send_decision
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  s public.dealer_settings; c public.contacts; d public.dealers; n public.channel_numbers; l public.leads;
  v_tz text; v_state char(2); v_start time; v_end time; v_sun time; sq public.state_quiet_hours;
  v_obeys_quiet boolean; v_open timestamptz;
  v_last_in timestamptz; v_window int;
  v_cap int; v_used int; v_day_start timestamptz; v_next_day timestamptz;
  v_norm text; v_tokens text[]; v_similar int; v_exempt boolean;
  v_res uuid; v_next timestamptz; v_existing public.send_reservations;
  v_consent_ok boolean;
begin
  if p_commit then
    perform pg_advisory_xact_lock(hashtextextended(p_number_id::text, 0));
    if p_idempotency_key is not null then
      select * into v_existing from public.send_reservations
       where dealer_id = p_dealer_id and idempotency_key = p_idempotency_key and status in ('reserved','sent');
      if found then
        return public._decision('allow','idempotent_replay','Same idempotency key already reserved.', null, v_existing.id);
      end if;
    end if;
  end if;

  select * into d from public.dealers where id = p_dealer_id;
  select * into s from public.dealer_settings where dealer_id = p_dealer_id;
  if d.id is null or s.dealer_id is null then
    return public._decision('veto','dealer_settings_missing','Dealer or dealer_settings row missing.');
  end if;
  select * into c from public.contacts where id = p_contact_id and dealer_id = p_dealer_id;
  if c.id is null then return public._decision('veto','contact_not_found','Contact not found for this dealer.'); end if;
  if c.is_anonymized then return public._decision('veto','contact_anonymized','Contact was anonymized; nothing may be sent.'); end if;
  select * into n from public.channel_numbers where id = p_number_id and dealer_id = p_dealer_id;
  if n.id is null then return public._decision('veto','number_not_found','Sending identity not found for this dealer.'); end if;
  if n.channel <> p_channel then return public._decision('veto','number_channel_mismatch','Sending identity belongs to a different channel.'); end if;
  if n.status <> 'active' then return public._decision('veto','number_inactive', format('Sending identity is %s.', n.status)); end if;
  if (p_channel in ('sms','whatsapp') and coalesce(c.phone_e164,'') = '') or (p_channel = 'email' and coalesce(c.email,'') = '') then
    return public._decision('veto','no_address','Contact has no address for this channel.');
  end if;

  if p_lead_id is not null then
    select * into l from public.leads where id = p_lead_id and dealer_id = p_dealer_id;
    if l.id is null or l.contact_id <> p_contact_id then
      return public._decision('veto','lead_contact_mismatch','Lead does not belong to this contact/dealer.');
    end if;
    if p_actor = 'ai' and (l.force_human or (l.bot_silenced_until is not null and l.bot_silenced_until > p_now)) then
      return public._decision('veto','human_owned','A person owns this conversation; the assistant is silenced.');
    end if;
  end if;

  -- 1) DNC: irrevocable, checked before anything about consent
  if exists (select 1 from public.contact_dnc x where x.contact_id = p_contact_id and x.cleared_at is null
                and (x.channel is null or x.channel = p_channel)) then
    return public._decision('veto','dnc_active','Contact opted out. Only the contact can re-opt-in.');
  end if;

  -- 2) consent or reply window
  if p_kind = 'reply' then
    select max(created_at) into v_last_in from public.messages
     where contact_id = p_contact_id and channel = p_channel and direction = 'inbound' and created_at <= p_now;
    v_window := case when p_channel = 'whatsapp' then least(24, s.reply_window_hours) else s.reply_window_hours end;
    if v_last_in is null or v_last_in < p_now - make_interval(hours => v_window) then
      return public._decision('veto', case when p_channel = 'whatsapp' then 'wa_window_closed' else 'reply_window_closed' end,
        format('No inbound %s from this contact in the last %s h; a reply is not allowed. Use an approved template (WhatsApp) or a consented follow-up.', p_channel, v_window),
        null, null, jsonb_build_object('last_inbound_at', v_last_in, 'requires_template', p_channel = 'whatsapp'));
    end if;
  else
    if p_kind = 'cold' and p_purpose <> 'marketing' then
      return public._decision('veto','cold_requires_marketing','First-touch outreach needs marketing-purpose consent.');
    end if;
    if not (p_channel = 'email' and not s.email_requires_consent) then
      select exists (select 1 from public.contact_consent_state cs
                      where cs.contact_id = p_contact_id and cs.channel = p_channel and cs.status = 'granted' and cs.evidence_ok
                        and public.purpose_rank(cs.purpose) >= public.purpose_rank(p_purpose)) into v_consent_ok;
      if not v_consent_ok then
        return public._decision('veto','no_consent', format('No valid %s consent on %s for this contact (grant needs provenance; marketing needs disclosure version).', p_purpose, p_channel));
      end if;
    end if;
  end if;

  -- 3) quiet hours at the RECIPIENT's local time (federal window intersected with state window)
  v_tz := coalesce(c.timezone, d.timezone);
  v_state := coalesce(c.state_code, d.state_code);
  v_start := s.quiet_start; v_end := s.quiet_end; v_sun := s.sunday_start;
  select * into sq from public.state_quiet_hours where state_code = v_state;
  if sq.state_code is not null then
    v_start := greatest(v_start, sq.start_time); v_end := least(v_end, sq.end_time);
    v_sun := case when sq.sunday_start is null then v_sun else greatest(coalesce(v_sun, v_start), sq.sunday_start) end;
  end if;
  v_obeys_quiet := not ((p_kind = 'reply' and s.reply_ignores_quiet) or (p_kind = 'transactional' and s.transactional_ignores_quiet))
                   and p_channel <> 'email';
  if v_obeys_quiet then
    v_open := public.next_window_open(p_now, v_tz, v_start, v_end, v_sun);
    if v_open > p_now then
      return public._decision('delay','quiet_hours', format('Outside %s-%s recipient-local (%s). Retry at not_before.', v_start, v_end, v_tz), v_open,
                              null, jsonb_build_object('tz', v_tz, 'state', v_state));
    end if;
  end if;

  -- 4) warm-up / daily cap on non-reply traffic
  if p_kind <> 'reply' then
    v_cap := public.number_daily_cap(p_number_id, p_now);
    if v_cap is not null then
      v_day_start := (((p_now at time zone d.timezone)::date)::timestamp) at time zone d.timezone;
      v_next_day  := ((((p_now at time zone d.timezone)::date + 1)::timestamp)) at time zone d.timezone;
      select count(*) into v_used from public.send_reservations r
       where r.number_id = p_number_id and r.kind <> 'reply' and r.status in ('reserved','sent')
         and r.reserved_at >= v_day_start and r.reserved_at < v_next_day;
      if v_used >= v_cap then
        v_open := case when v_obeys_quiet then public.next_window_open(v_next_day, v_tz, v_start, v_end, v_sun) else v_next_day end;
        return public._decision('delay','daily_cap', format('Daily cap %s reached for this number (used %s).', v_cap, v_used), v_open,
                                null, jsonb_build_object('cap', v_cap, 'used', v_used));
      end if;
    end if;
  end if;

  -- 5) throttle + jitter: one send slot at a time per identity
  if n.next_allowed_at is not null and n.next_allowed_at > p_now then
    return public._decision('delay','throttle','Per-number throttle; retry at not_before.', n.next_allowed_at);
  end if;

  -- 6) anti-template (free-form copy only; approved templates are exempt)
  if p_body is not null and not p_is_template then
    v_norm := public.normalize_copy(p_body);
    v_exempt := length(v_norm) <= n.spin_allow_max_len or v_norm ~* n.spin_allow_regex;
    if not v_exempt then
      v_tokens := public.copy_tokens(v_norm);
      select count(*) into v_similar from (
        select r.body_norm from public.send_reservations r
         where r.number_id = p_number_id and r.status in ('reserved','sent') and r.body_norm is not null and not r.is_template
         order by r.reserved_at desc limit n.spin_window
      ) w where w.body_norm = v_norm or public.jaccard(public.copy_tokens(w.body_norm), v_tokens) >= n.spin_threshold;
      if v_similar >= n.spin_repetition then
        return public._decision('veto','template_repetition',
          format('This copy is >=%s similar to %s recent messages from this number. Rewrite it in different words.', n.spin_threshold, v_similar),
          null, null, jsonb_build_object('similar', v_similar));
      end if;
    end if;
  end if;

  if not p_commit then
    return public._decision('allow','ok','Would be allowed.', null, null,
      jsonb_build_object('tz', v_tz, 'cap', v_cap, 'used', v_used));
  end if;

  insert into public.send_reservations(dealer_id, number_id, contact_id, lead_id, channel, purpose, kind, actor, body_norm, is_template, idempotency_key, reserved_at)
  values (p_dealer_id, p_number_id, p_contact_id, p_lead_id, p_channel, p_purpose, p_kind, p_actor, v_norm, p_is_template, p_idempotency_key, p_now)
  returning id into v_res;
  v_next := p_now + make_interval(secs => (n.throttle_ms + floor(random() * (n.jitter_max_ms + 1))) / 1000.0);
  update public.channel_numbers set next_allowed_at = v_next where id = p_number_id;
  return public._decision('allow','reserved','Slot reserved.', null, v_res, jsonb_build_object('next_allowed_at', v_next, 'cap', v_cap, 'used', coalesce(v_used,0) + 1));
end $$;

create or replace function public.confirm_send(p_reservation_id uuid, p_message_id uuid default null, p_now timestamptz default now())
returns void language sql security definer set search_path = public, pg_temp as $$
  update public.send_reservations set status = 'sent', message_id = p_message_id, sent_at = p_now
   where id = p_reservation_id and status = 'reserved'
$$;

create or replace function public.release_send(p_reservation_id uuid, p_reason text default null)
returns void language sql security definer set search_path = public, pg_temp as $$
  update public.send_reservations set status = 'released', released_reason = p_reason
   where id = p_reservation_id and status = 'reserved'
$$;

-- Convenience for the inbound webhook: record a STOP-style opt-out and return the contact's open DNC.
create or replace function public.record_opt_out(p_dealer_id uuid, p_contact_id uuid, p_channel public.channel_kind,
                                                 p_source public.consent_source default 'sms_keyword',
                                                 p_evidence jsonb default '{}'::jsonb, p_note text default 'STOP keyword')
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  insert into public.consent_events(dealer_id, contact_id, channel, purpose, action, source, evidence, note)
  values (p_dealer_id, p_contact_id, p_channel, null, 'revoke', p_source, p_evidence, p_note) returning id into v_id;
  -- cancel anything queued for this contact/channel
  update public.followups f set status = 'cancelled'
   where f.dealer_id = p_dealer_id and f.status in ('scheduled','due')
     and f.lead_id in (select id from public.leads where contact_id = p_contact_id);
  return v_id;
end $$;

-- =====================================================================================
-- PART B. GUARDRAILED AGENT
-- =====================================================================================
do $$ begin create type public.agent_trigger as enum ('inbound_message','followup_due','briefing_draft','manual'); exception when duplicate_object then null; end $$;
do $$ begin create type public.agent_run_status as enum ('running','completed','failed','budget_blocked','escalated','cancelled'); exception when duplicate_object then null; end $$;
do $$ begin create type public.inbox_kind as enum ('handoff','needs_review','classification_review','send_failed','stale_draft','ambiguous_stop','budget_blocked','promise_blocked','channel_down','legal_threat'); exception when duplicate_object then null; end $$;

create table if not exists public.agent_runs (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  lead_id uuid references public.leads(id) on delete set null,
  contact_id uuid references public.contacts(id) on delete set null,
  trigger public.agent_trigger not null,
  trigger_ref uuid,                                         -- message id / followup id / briefing item id
  status public.agent_run_status not null default 'running',
  provider text, model text, prompt_version text,
  steps int not null default 0,
  input_tokens int not null default 0, output_tokens int not null default 0,
  cost_cents numeric(12,4) not null default 0,
  error text,
  started_at timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists agent_runs_dealer_started_idx on public.agent_runs (dealer_id, started_at desc);
create index if not exists agent_runs_lead_idx on public.agent_runs (lead_id, started_at desc);
create index if not exists agent_runs_failed_idx on public.agent_runs (dealer_id, started_at desc) where status = 'failed';

create table if not exists public.agent_tool_calls (
  id uuid primary key default gen_random_uuid(),
  run_id uuid not null references public.agent_runs(id) on delete cascade,
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  step int not null default 0,
  tool text not null,
  args jsonb not null default '{}'::jsonb,                 -- redact PII before insert
  result_code text,                                         -- ok | <teaching error code>
  duration_ms int,
  created_at timestamptz not null default now()
);
create index if not exists agent_tool_calls_run_idx on public.agent_tool_calls (run_id, step);

-- The reviewable queue between "model proposed a message" and "message left the building".
create table if not exists public.outbound_drafts (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  lead_id uuid references public.leads(id) on delete cascade,
  contact_id uuid not null references public.contacts(id) on delete cascade,
  channel public.channel_kind not null,
  number_id uuid not null references public.channel_numbers(id) on delete restrict,
  run_id uuid references public.agent_runs(id) on delete set null,
  actor text not null default 'ai' check (actor in ('ai','human','system')),
  purpose public.consent_purpose not null default 'conversational',
  kind public.send_kind not null default 'reply',
  reply_for_message_id uuid references public.messages(id) on delete set null,
  body_ai text not null,
  body_edited text,
  status text not null default 'awaiting_review' check (status in
    ('held','awaiting_review','delayed','sending','sent','discarded','vetoed','failed','stale','handed_to_rep')),
  release_at timestamptz,                                   -- when the sweeper may pick it up (hold end or delay end)
  expected_context_version int,                             -- leads.context_version when the draft was written
  evidence jsonb not null default '{}'::jsonb,              -- tool evidence the gates used (vins, quotes, appointments)
  chain_version int,
  veto_code text,
  reservation_id uuid references public.send_reservations(id) on delete set null,
  message_id uuid,
  approved_by uuid, approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists outbound_drafts_due_idx on public.outbound_drafts (release_at) where status in ('held','delayed') and release_at is not null;
create index if not exists outbound_drafts_lead_idx on public.outbound_drafts (lead_id, created_at desc);
create index if not exists outbound_drafts_review_idx on public.outbound_drafts (dealer_id, created_at) where status in ('held','awaiting_review','delayed');

create table if not exists public.before_send_traces (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  draft_id uuid references public.outbound_drafts(id) on delete cascade,
  run_id uuid references public.agent_runs(id) on delete set null,
  attempt int not null default 1,
  chain_version int not null,
  gate text not null,
  verdict text not null check (verdict in ('allow','veto','delay','hold')),
  code text,
  detail jsonb not null default '{}'::jsonb,                -- never store the body here (PII); store counts/ids only
  created_at timestamptz not null default now()
);
create index if not exists before_send_traces_draft_idx on public.before_send_traces (draft_id, created_at);
create index if not exists before_send_traces_dealer_idx on public.before_send_traces (dealer_id, created_at desc);

create table if not exists public.agent_inbox_items (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  lead_id uuid references public.leads(id) on delete cascade,
  run_id uuid references public.agent_runs(id) on delete set null,
  draft_id uuid references public.outbound_drafts(id) on delete set null,
  kind public.inbox_kind not null,
  priority smallint not null default 2 check (priority between 1 and 3),    -- 1 = urgent
  title text not null,
  summary text,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'open' check (status in ('open','resolved','dismissed')),
  assigned_to uuid,
  created_at timestamptz not null default now(),
  resolved_at timestamptz, resolved_by uuid
);
create index if not exists agent_inbox_open_idx on public.agent_inbox_items (dealer_id, priority, created_at desc) where status = 'open';
-- one open item per (lead, kind): repeated vetoes must not spam the desk
create unique index if not exists agent_inbox_open_uq on public.agent_inbox_items (lead_id, kind) where status = 'open' and lead_id is not null;

-- ---------- triggers on messages: bookkeeping + "a customer reply invalidates pending AI work" ----------
create or replace function public.messages_after_insert() returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.lead_id is null then return new; end if;
  if new.direction = 'inbound' then
    update public.leads set last_inbound_at = new.created_at, context_version = context_version + 1, updated_at = now() where id = new.lead_id;
    update public.outbound_drafts set status = 'stale', updated_at = now()
     where lead_id = new.lead_id and status in ('held','awaiting_review','delayed') and actor = 'ai' and kind in ('reply','followup');
    update public.followups set status = 'cancelled' where lead_id = new.lead_id and status in ('scheduled','due') and kind in ('sequence','stalled');
  else
    update public.leads set last_outbound_at = new.created_at, updated_at = now() where id = new.lead_id;
  end if;
  return new;
end $$;
drop trigger if exists messages_after_insert_trg on public.messages;
create trigger messages_after_insert_trg after insert on public.messages for each row execute function public.messages_after_insert();

-- ---------- forward-only stage policy (AgentSDR idea; AI may only move a lead forward) ----------
create or replace function public.lead_stage_rank(p text) returns int language sql immutable as $$
  select case p when 'new' then 1 when 'contacted' then 2 when 'qualifying' then 3 when 'qualified' then 4
                when 'test_drive' then 5 when 'negotiating' then 6 when 'won' then 7 when 'lost' then 0 else null end
$$;

-- returns 'applied' | 'review' | 'noop'. 'lost' and backward moves never auto-apply (a rep must confirm).
create or replace function public.apply_lead_stage(p_dealer_id uuid, p_lead_id uuid, p_to text, p_actor_kind text,
  p_confidence numeric, p_reason text, p_evidence jsonb default '{}'::jsonb, p_min_confidence numeric default 0.85,
  p_actor_id uuid default null)
returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare v_from text; v_decision text;
begin
  select stage into v_from from public.leads where id = p_lead_id and dealer_id = p_dealer_id for update;
  if v_from is null then raise exception 'lead not found'; end if;
  if public.lead_stage_rank(p_to) is null then raise exception 'unknown stage %', p_to; end if;
  if v_from = p_to then return 'noop'; end if;
  if p_actor_kind = 'human' then v_decision := 'applied';
  elsif p_to = 'lost' or p_to = 'won' then v_decision := 'review';
  elsif public.lead_stage_rank(p_to) < public.lead_stage_rank(v_from) then v_decision := 'review';
  elsif coalesce(p_confidence, 0) < p_min_confidence then v_decision := 'review';
  else v_decision := 'applied'; end if;
  if v_decision = 'applied' then
    update public.leads set stage = p_to, updated_at = now() where id = p_lead_id;
  end if;
  insert into public.lead_activities(dealer_id, lead_id, actor_kind, actor_id, kind, from_stage, to_stage, confidence, reason, evidence)
  values (p_dealer_id, p_lead_id, p_actor_kind, p_actor_id, case when v_decision = 'applied' then 'stage_changed' else 'stage_change_proposed' end,
          v_from, p_to, p_confidence, p_reason, p_evidence);
  if v_decision = 'review' then
    insert into public.agent_inbox_items(dealer_id, lead_id, kind, priority, title, summary, payload)
    values (p_dealer_id, p_lead_id, 'classification_review', 2, format('Confirm stage: %s -> %s', v_from, p_to), p_reason,
            jsonb_build_object('from', v_from, 'to', p_to, 'confidence', p_confidence))
    on conflict (lead_id, kind) where status = 'open' and lead_id is not null do nothing;
  end if;
  return v_decision;
end $$;

-- ---------- circuit breaker (AgenticCRM idea): >=5 failed runs in 10 minutes => stop calling the model ----------
create or replace function public.agent_breaker_open(p_dealer_id uuid, p_now timestamptz default now())
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select count(*) >= 5 from public.agent_runs
   where dealer_id = p_dealer_id and status = 'failed' and started_at > p_now - interval '10 minutes'
$$;

-- ---------- rep hold queue ----------
-- Sweeper claims drafts whose hold/delay expired. FOR UPDATE SKIP LOCKED => safe with parallel workers.
create or replace function public.claim_due_drafts(p_limit int default 50, p_now timestamptz default now())
returns setof public.outbound_drafts language sql security definer set search_path = public, pg_temp as $$
  update public.outbound_drafts d set status = 'sending', updated_at = p_now
   where d.id in (
     select id from public.outbound_drafts
      where status in ('held','delayed') and release_at is not null and release_at <= p_now
      order by release_at for update skip locked limit p_limit)
  returning d.*
$$;

-- Hourly: drafts nobody sent within followup_handoff_hours go to a rep (AgentSDR's 48h rule).
create or replace function public.handoff_stale_drafts(p_now timestamptz default now())
returns int language plpgsql security definer set search_path = public, pg_temp as $$
declare v_n int := 0; r record;
begin
  for r in
    select d.id, d.dealer_id, d.lead_id from public.outbound_drafts d
      join public.dealer_settings s on s.dealer_id = d.dealer_id
     where d.status in ('held','awaiting_review','delayed')
       and d.created_at < p_now - make_interval(hours => s.followup_handoff_hours)
     for update of d skip locked
  loop
    update public.outbound_drafts set status = 'handed_to_rep', updated_at = p_now where id = r.id;
    insert into public.agent_inbox_items(dealer_id, lead_id, draft_id, kind, priority, title, summary)
    values (r.dealer_id, r.lead_id, r.id, 'stale_draft', 2, 'Draft unsent for 48h', 'The timing it was written for has probably passed; review or discard.')
    on conflict (lead_id, kind) where status = 'open' and lead_id is not null do nothing;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

create or replace function public.prune_agent_telemetry(p_now timestamptz default now())
returns void language sql security definer set search_path = public, pg_temp as $$
  delete from public.before_send_traces where created_at < p_now - interval '90 days';
  delete from public.agent_tool_calls   where created_at < p_now - interval '90 days';
  delete from public.send_reservations  where reserved_at < p_now - interval '45 days' and status <> 'reserved';
$$;

-- =====================================================================================
-- PART C. MORNING DRIVE BRIEFING
-- =====================================================================================
do $$ begin create type public.briefing_status as enum ('pending','building','ready','delivered','failed','skipped'); exception when duplicate_object then null; end $$;

create table if not exists public.daily_briefings (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  user_id uuid not null,
  local_date date not null,                                  -- the dealer-local day this briefing is for
  status public.briefing_status not null default 'pending',
  attempts int not null default 0,
  facts jsonb not null default '{}'::jsonb,                  -- frozen counts/ids only (no names/phones/message text)
  narrative text,                                            -- LLM narration; items carry deterministic fallbacks
  error text,
  claimed_at timestamptz,
  built_at timestamptz, delivered_at timestamptz,
  created_at timestamptz not null default now(),
  unique (user_id, local_date)
);
create index if not exists daily_briefings_status_idx on public.daily_briefings (status, created_at) where status in ('pending','building');
create index if not exists daily_briefings_dealer_day_idx on public.daily_briefings (dealer_id, local_date);

create table if not exists public.briefing_items (
  id uuid primary key default gen_random_uuid(),
  briefing_id uuid not null references public.daily_briefings(id) on delete cascade,
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  rank int not null check (rank >= 1),
  lead_id uuid not null references public.leads(id) on delete cascade,
  kind public.briefing_item_kind not null,
  score numeric not null,
  score_parts jsonb not null default '{}'::jsonb,            -- {weight,value,ramp,decay,reach,age_h}
  reason_text text not null,                                 -- deterministic "why now" (LLM may rewrite)
  evidence jsonb not null default '{}'::jsonb,
  draft_id uuid references public.outbound_drafts(id) on delete set null,
  state text not null default 'open' check (state in ('open','done','snoozed','dismissed')),
  acted_at timestamptz,
  created_at timestamptz not null default now(),
  unique (briefing_id, rank)
);
create index if not exists briefing_items_lead_idx on public.briefing_items (lead_id);
create index if not exists briefing_items_briefing_idx on public.briefing_items (briefing_id, rank);

-- scoring knobs (global defaults; one row per kind)
create table if not exists public.briefing_kind_config (
  kind public.briefing_item_kind primary key,
  weight numeric not null check (weight between 0 and 1),
  ramp_hours numeric not null default 0,                     -- >0: urgency climbs from 0.4 to 1.0 over this many hours
  grace_hours numeric not null default 24,                   -- no decay before this age
  half_life_hours numeric not null check (half_life_hours > 0)
);
insert into public.briefing_kind_config(kind, weight, ramp_hours, grace_hours, half_life_hours) values
  ('waiting_reply',     1.00,    2,   24,  48),
  ('test_drive_today',  0.95,    0,   12,  12),
  ('test_drive_noshow', 0.90,    0,   24,  36),
  ('callback_due',      0.85,    4,   24,  48),
  ('hot_gone_quiet',    0.80,   96,  168,  96),
  ('price_drop_viewed', 0.70,    0,   24,  36),
  ('trade_in_pending',  0.65,    8,   48,  72),
  ('lease_ending',      0.60, 2160, 2400, 168)
on conflict (kind) do nothing;

-- ---------- candidate views (security_invoker => caller's RLS applies; service role sees all) ----------
-- dealer-local "today" comes from dealers.timezone. Every view returns the same 6 columns.
create or replace view public.v_cand_waiting_reply with (security_invoker = true) as
select l.dealer_id, l.id as lead_id, l.assigned_to as owner_user_id, 'waiting_reply'::public.briefing_item_kind as kind,
       l.last_inbound_at as event_at, l.value_cents,
       jsonb_build_object('last_inbound_at', l.last_inbound_at) as evidence
  from public.leads l
 where l.stage not in ('won','lost') and l.last_inbound_at is not null
   and l.last_inbound_at > coalesce(l.last_outbound_at, '-infinity'::timestamptz)
   and l.last_inbound_at < now() - interval '10 minutes';

create or replace view public.v_cand_test_drive_today with (security_invoker = true) as
select a.dealer_id, a.lead_id, l.assigned_to, 'test_drive_today'::public.briefing_item_kind,
       a.starts_at, l.value_cents,
       jsonb_build_object('appointment_id', a.id, 'starts_at', a.starts_at, 'kind', a.kind, 'status', a.status, 'vehicle_id', a.vehicle_id)
  from public.appointments a
  join public.leads l on l.id = a.lead_id
  join public.dealers d on d.id = a.dealer_id
 where a.kind in ('test_drive','showroom') and a.status in ('requested','confirmed')
   and (a.starts_at at time zone d.timezone)::date = (now() at time zone d.timezone)::date
   and a.starts_at >= now() - interval '30 minutes';

create or replace view public.v_cand_test_drive_noshow with (security_invoker = true) as
select a.dealer_id, a.lead_id, l.assigned_to, 'test_drive_noshow'::public.briefing_item_kind,
       a.starts_at, l.value_cents,
       jsonb_build_object('appointment_id', a.id, 'starts_at', a.starts_at, 'status', a.status, 'vehicle_id', a.vehicle_id)
  from public.appointments a
  join public.leads l on l.id = a.lead_id
 where a.kind in ('test_drive','showroom') and l.stage not in ('won','lost')
   and (a.status = 'no_show' or (a.status in ('requested','confirmed') and a.starts_at < now() - interval '45 minutes'))
   and a.starts_at > now() - interval '36 hours';

create or replace view public.v_cand_callback_due with (security_invoker = true) as
select f.dealer_id, f.lead_id, coalesce(f.assigned_to, l.assigned_to), 'callback_due'::public.briefing_item_kind,
       f.due_at, l.value_cents,
       jsonb_build_object('followup_id', f.id, 'followup_kind', f.kind, 'reason', f.reason, 'promised_text', f.promised_text)
  from public.followups f
  join public.leads l on l.id = f.lead_id
 where f.status in ('scheduled','due') and f.due_at <= now() and l.stage not in ('won','lost');

create or replace view public.v_cand_hot_gone_quiet with (security_invoker = true) as
select l.dealer_id, l.id, l.assigned_to, 'hot_gone_quiet'::public.briefing_item_kind,
       greatest(coalesce(l.last_inbound_at, l.created_at), coalesce(l.last_outbound_at, l.created_at)) as event_at, l.value_cents,
       jsonb_build_object('stage', l.stage,
                          'views_7d', (select count(*) from public.lead_vehicle_views v where v.lead_id = l.id and v.viewed_at > now() - interval '7 days')) as evidence
  from public.leads l
 where l.stage in ('qualified','test_drive','negotiating')
   and greatest(coalesce(l.last_inbound_at, l.created_at), coalesce(l.last_outbound_at, l.created_at)) < now() - interval '72 hours'
   and greatest(coalesce(l.last_inbound_at, l.created_at), coalesce(l.last_outbound_at, l.created_at)) > now() - interval '21 days'
   and not exists (select 1 from public.followups f where f.lead_id = l.id and f.status in ('scheduled','due'));

create or replace view public.v_cand_price_drop_viewed with (security_invoker = true) as
select distinct on (l.id, e.vehicle_id)
       l.dealer_id, l.id, l.assigned_to, 'price_drop_viewed'::public.briefing_item_kind,
       e.changed_at, l.value_cents,
       jsonb_build_object('vehicle_id', e.vehicle_id, 'vin', v.vin, 'old_price_cents', e.old_price_cents,
                          'new_price_cents', e.new_price_cents, 'drop_cents', e.old_price_cents - e.new_price_cents)
  from public.vehicle_price_events e
  join public.vehicles v on v.id = e.vehicle_id and v.status = 'available'
  join public.lead_vehicle_views lv on lv.vehicle_id = e.vehicle_id and lv.viewed_at > now() - interval '30 days'
  join public.leads l on l.id = lv.lead_id and l.dealer_id = e.dealer_id
 where e.new_price_cents < e.old_price_cents and e.changed_at > now() - interval '48 hours'
   and l.stage not in ('won','lost')
 order by l.id, e.vehicle_id, e.changed_at desc;

create or replace view public.v_cand_trade_in_pending with (security_invoker = true) as
select t.dealer_id, t.lead_id, l.assigned_to, 'trade_in_pending'::public.briefing_item_kind,
       t.requested_at, l.value_cents,
       jsonb_build_object('appraisal_id', t.id, 'status', t.status, 'year', t.year, 'make', t.make, 'model', t.model)
  from public.trade_in_appraisals t
  join public.leads l on l.id = t.lead_id
 where t.status in ('requested','in_review') and t.requested_at < now() - interval '4 hours' and l.stage not in ('won','lost');

create or replace view public.v_cand_lease_ending with (security_invoker = true) as
select l.dealer_id, l.id, l.assigned_to, 'lease_ending'::public.briefing_item_kind,
       (l.lease_end_on - 90)::timestamptz as event_at, l.value_cents,
       jsonb_build_object('lease_end_on', l.lease_end_on, 'days_left', l.lease_end_on - current_date)
  from public.leads l
 where l.lease_end_on is not null and l.lease_end_on between current_date and current_date + 90 and l.stage not in ('won','lost');

create or replace view public.briefing_candidates with (security_invoker = true) as
select u.dealer_id, u.lead_id, u.owner_user_id, u.kind, u.event_at, u.value_cents, u.evidence,
       (c.id is not null and not exists (select 1 from public.contact_dnc x where x.contact_id = c.id and x.cleared_at is null and x.channel is null)
        and (coalesce(c.phone_e164,'') <> '' or coalesce(c.email,'') <> '')) as contact_reachable
  from (
    select * from public.v_cand_waiting_reply union all
    select * from public.v_cand_test_drive_today union all
    select * from public.v_cand_test_drive_noshow union all
    select * from public.v_cand_callback_due union all
    select * from public.v_cand_hot_gone_quiet union all
    select * from public.v_cand_price_drop_viewed union all
    select * from public.v_cand_trade_in_pending union all
    select * from public.v_cand_lease_ending
  ) u
  join public.leads l on l.id = u.lead_id
  left join public.contacts c on c.id = l.contact_id;

-- ---------- deterministic score ----------
--   score = weight * value_factor * ramp * decay * reach
--   value_factor = 0.5 + 0.5 * min(1, ln(1 + $deal)/ln(1 + $50k))
--   ramp   = min(1, 0.4 + 0.6 * age_h / ramp_hours)         (urgency climbs while a customer waits)
--   decay  = 0.5 ^ (max(0, age_h - grace_h) / half_life_h)   (stale items fade; AgenticCRM-style half-life)
--   reach  = 1 if contactable else 0.6                       (still shown, ranked lower, no draft)
create or replace function public.briefing_score(p_kind public.briefing_item_kind, p_event_at timestamptz,
  p_value_cents bigint, p_reachable boolean, p_now timestamptz default now())
returns table (score numeric, parts jsonb) language plpgsql stable as $$
declare cfg public.briefing_kind_config; age_h numeric; v_ramp numeric; v_decay numeric; v_value numeric; v_reach numeric;
begin
  select * into cfg from public.briefing_kind_config where kind = p_kind;
  age_h   := greatest(0, extract(epoch from (p_now - p_event_at)) / 3600.0);
  v_ramp  := case when cfg.ramp_hours > 0 then least(1, 0.4 + 0.6 * age_h / cfg.ramp_hours) else 1 end;
  v_decay := power(0.5, greatest(0, age_h - cfg.grace_hours) / cfg.half_life_hours);
  v_value := 0.5 + 0.5 * least(1, ln(1 + coalesce(p_value_cents, 0) / 100.0) / ln(1 + 50000));
  v_reach := case when p_reachable then 1 else 0.6 end;
  score := round(cfg.weight * v_value * v_ramp * v_decay * v_reach, 6);
  parts := jsonb_build_object('weight', cfg.weight, 'value', round(v_value, 4), 'ramp', round(v_ramp, 4),
                              'decay', round(v_decay, 4), 'reach', v_reach, 'age_h', round(age_h, 2));
  return next;
end $$;

create or replace function public.age_text(p interval) returns text language sql immutable as $$
  select case when p < interval '1 hour' then greatest(1, floor(extract(epoch from p)/60))::int || ' min'
              when p < interval '48 hours' then floor(extract(epoch from p)/3600)::int || ' h'
              else floor(extract(epoch from p)/86400)::int || ' days' end
$$;

create or replace function public.briefing_reason_text(p_kind public.briefing_item_kind, p_evidence jsonb, p_event_at timestamptz, p_now timestamptz default now())
returns text language sql immutable as $$
  select case p_kind
    when 'waiting_reply'     then format('Customer wrote %s ago and is still waiting on a reply.', public.age_text(p_now - p_event_at))
    when 'test_drive_today'  then 'Test drive or showroom visit scheduled today.'
    when 'test_drive_noshow' then 'Missed a scheduled visit; reach out while the interest is warm.'
    when 'callback_due'      then format('Promised callback is due%s.', coalesce(': ' || nullif(p_evidence->>'reason',''), ''))
    when 'hot_gone_quiet'    then format('Qualified lead silent for %s (stage: %s).', public.age_text(p_now - p_event_at), p_evidence->>'stage')
    when 'price_drop_viewed' then format('Price dropped $%s on a vehicle they viewed.', round(((p_evidence->>'drop_cents')::numeric) / 100))
    when 'trade_in_pending'  then format('Trade-in appraisal waiting %s.', public.age_text(p_now - p_event_at))
    when 'lease_ending'      then format('Lease ends in %s days.', p_evidence->>'days_left')
  end
$$;


-- ---------- build one briefing: rank, dedupe per lead, keep top N (deterministic; the LLM only narrates) ----------
create or replace function public.build_briefing_items(p_briefing_id uuid, p_now timestamptz default now())
returns int language plpgsql security definer set search_path = public, pg_temp as $$
declare b public.daily_briefings; v_role text; v_size int; v_n int; v_total int; v_by jsonb;
begin
  select * into b from public.daily_briefings where id = p_briefing_id for update;
  if b.id is null then raise exception 'briefing % not found', p_briefing_id; end if;
  if b.status = 'delivered' then return 0; end if;
  select m.role::text into v_role from public.dealer_members m where m.user_id = b.user_id and m.dealer_id = b.dealer_id;
  select briefing_size into v_size from public.dealer_settings where dealer_id = b.dealer_id;
  delete from public.briefing_items where briefing_id = b.id;

  drop table if exists _cands;
  create temp table _cands on commit drop as
  select c.*, s.score, s.parts,
         array_agg(c.kind) over (partition by c.lead_id) as all_kinds
    from public.briefing_candidates c
    cross join lateral public.briefing_score(c.kind, c.event_at, c.value_cents, c.contact_reachable, p_now) s
   where c.dealer_id = b.dealer_id
     and (c.owner_user_id = b.user_id or (c.owner_user_id is null and coalesce(v_role,'') in ('owner','admin','manager','bdc')));

  select count(*) into v_total from _cands;
  select coalesce(jsonb_object_agg(kind, n), '{}'::jsonb) into v_by from (select kind, count(*) n from _cands group by kind) x;

  with best as (select distinct on (lead_id) * from _cands order by lead_id, score desc, event_at asc),
       ranked as (select *, row_number() over (order by score desc, event_at asc, lead_id) rn from best)
  insert into public.briefing_items (briefing_id, dealer_id, rank, lead_id, kind, score, score_parts, reason_text, evidence)
  select b.id, b.dealer_id, rn, lead_id, kind, score, parts,
         public.briefing_reason_text(kind, evidence, event_at, p_now),
         evidence || jsonb_build_object('also_kinds', to_jsonb(array(select k from unnest(all_kinds) k where k <> ranked.kind)),
                                        'contact_reachable', contact_reachable, 'event_at', event_at)
    from ranked where rn <= v_size;
  get diagnostics v_n = row_count;
  drop table _cands;

  update public.daily_briefings
     set facts = jsonb_build_object('total_candidates', v_total, 'by_kind', v_by, 'size', v_size, 'built_for', p_now), built_at = p_now
   where id = b.id;
  return v_n;
end $$;

-- ---------- enqueue by store timezone (pg_cron ticks every 15 min in UTC; this decides who is "due") ----------
create or replace function public.enqueue_due_briefings(p_now timestamptz default now())
returns int language plpgsql security definer set search_path = public, pg_temp as $$
declare v_n int;
begin
  with due as (
    select m.user_id, m.dealer_id, (p_now at time zone d.timezone)::date as local_date
      from public.dealers d
      join public.dealer_settings s on s.dealer_id = d.id and s.briefing_enabled
      join public.dealer_members m on m.dealer_id = d.id and m.briefing_enabled and m.role::text in ('owner','admin','manager','sales','bdc')
     where (p_now at time zone d.timezone)::time >= s.briefing_local_time
       and (p_now at time zone d.timezone)::time <  s.briefing_local_time + interval '3 hours'   -- a late tick still builds a morning briefing, never an afternoon one
       and extract(isodow from (p_now at time zone d.timezone)) = any (s.briefing_days)
  ), ins as (
    insert into public.daily_briefings (dealer_id, user_id, local_date)
    select dealer_id, user_id, local_date from due
    on conflict (user_id, local_date) do nothing
    returning 1)
  select count(*) into v_n from ins;
  return v_n;
end $$;

-- Worker claim: pending (or stale 'building' > 10 min) -> building. SKIP LOCKED => parallel-safe.
create or replace function public.claim_pending_briefings(p_limit int default 20, p_now timestamptz default now())
returns setof public.daily_briefings language sql security definer set search_path = public, pg_temp as $$
  update public.daily_briefings b set status = 'building', claimed_at = p_now, attempts = attempts + 1
   where b.id in (
     select id from public.daily_briefings
      where (status = 'pending' or (status = 'building' and claimed_at < p_now - interval '10 minutes')) and attempts < 5
      order by created_at for update skip locked limit p_limit)
  returning b.*
$$;

-- Manager command-center rollup: per rep per day
create or replace view public.v_briefing_manager_rollup with (security_invoker = true) as
select b.dealer_id, b.local_date, b.user_id, b.status,
       count(i.id) as items_total,
       count(i.id) filter (where i.state = 'done') as items_done,
       count(i.id) filter (where i.kind = 'waiting_reply') as waiting_reply,
       count(i.id) filter (where i.kind in ('test_drive_today','test_drive_noshow')) as appointments,
       count(i.id) filter (where i.kind = 'hot_gone_quiet') as stuck_deals,
       coalesce(sum(i.score), 0) as total_score
  from public.daily_briefings b left join public.briefing_items i on i.briefing_id = b.id
 group by b.dealer_id, b.local_date, b.user_id, b.status;

-- =====================================================================================
-- PART D. SCHEDULING (pg_cron + pg_net, both guarded) and Edge Function kickers
-- =====================================================================================
-- Calls POST {project_url}/functions/v1/<name> with the service-role key stored in Vault.
-- Setup once:  select vault.create_secret('https://<ref>.supabase.co', 'project_url');
--              select vault.create_secret('<service_role_key>', 'service_role_key');
-- No-ops (with a NOTICE) when pg_net/vault are missing, so local dev and CI still apply the migration.
create or replace function public.invoke_edge_function(p_name text, p_body jsonb default '{}'::jsonb)
returns bigint language plpgsql security definer set search_path = public, pg_temp as $$
declare v_url text; v_key text; v_id bigint;
begin
  if to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null or to_regclass('vault.decrypted_secrets') is null then
    raise notice 'invoke_edge_function(%): pg_net/vault not available; skipped', p_name;
    return null;
  end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = ''project_url'' limit 1' into v_url;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = ''service_role_key'' limit 1' into v_key;
  if v_url is null or v_key is null then
    raise notice 'invoke_edge_function(%): vault secrets project_url/service_role_key missing; skipped', p_name;
    return null;
  end if;
  execute 'select net.http_post(url := $1, body := $2, headers := $3, timeout_milliseconds := 10000)'
    into v_id
    using v_url || '/functions/v1/' || p_name, p_body,
          jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Bearer ' || v_key);
  return v_id;
end $$;

create or replace function public.kick_briefing_worker() returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if exists (select 1 from public.daily_briefings where (status = 'pending' or (status = 'building' and claimed_at < now() - interval '10 minutes')) and attempts < 5) then
    perform public.invoke_edge_function('morning-briefing');
  end if;
end $$;

create or replace function public.kick_outbound_sweeper() returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if exists (select 1 from public.outbound_drafts where status in ('held','delayed') and release_at is not null and release_at <= now()) then
    perform public.invoke_edge_function('outbound-sweeper');
  end if;
end $$;

-- pg_cron runs in UTC. Per-store timezone logic lives in enqueue_due_briefings(), so a single 15-minute tick serves every timezone.
do $cron$
begin
  begin
    create extension if not exists pg_cron;
  exception when others then
    raise notice 'pg_cron not available (%); skipping schedules. Apply them manually where pg_cron exists.', sqlerrm;
    return;
  end;
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron schema not usable; skipping schedules'; return;
  end if;
  perform cron.schedule('salesos-briefing-enqueue', '*/15 * * * *', $$select public.enqueue_due_briefings()$$);
  perform cron.schedule('salesos-briefing-process', '*/5 * * * *',  $$select public.kick_briefing_worker()$$);
  perform cron.schedule('salesos-outbound-sweep',   '* * * * *',    $$select public.kick_outbound_sweeper()$$);
  perform cron.schedule('salesos-stale-drafts',     '7 * * * *',    $$select public.handoff_stale_drafts()$$);
  perform cron.schedule('salesos-prune',            '30 3 * * *',   $$select public.prune_agent_telemetry()$$);
exception when others then
  raise notice 'pg_cron scheduling skipped: %', sqlerrm;
end
$cron$;

-- =====================================================================================
-- PART E. RLS + GRANTS (all tenant data scoped by dealer_id; service_role bypasses RLS)
-- =====================================================================================
do $rls$
declare t text;
  tenant_tables text[] := array[
    'dealer_settings','channel_numbers','consent_events','contact_consent_state','contact_dnc','send_reservations',
    'ai_budgets','agent_runs','agent_tool_calls','outbound_drafts','before_send_traces','agent_inbox_items',
    'daily_briefings','briefing_items','lead_activities','followups','appointments','trade_in_appraisals',
    'vehicle_price_events','lead_vehicle_views','messages'];
begin
  foreach t in array tenant_tables loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists %I on public.%I', t || '_member_select', t);
    execute format('create policy %I on public.%I for select to authenticated using (public.is_dealer_member(dealer_id))', t || '_member_select', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
end
$rls$;

alter table public.state_quiet_hours enable row level security;
alter table public.briefing_kind_config enable row level security;
drop policy if exists state_quiet_hours_read on public.state_quiet_hours;
create policy state_quiet_hours_read on public.state_quiet_hours for select to authenticated using (true);
drop policy if exists briefing_kind_config_read on public.briefing_kind_config;
create policy briefing_kind_config_read on public.briefing_kind_config for select to authenticated using (true);
revoke all on public.state_quiet_hours, public.briefing_kind_config from anon, authenticated;
grant select on public.state_quiet_hours, public.briefing_kind_config to authenticated;

-- briefings: a rep sees only their own; managers/owners/admins see the dealer's
drop policy if exists daily_briefings_member_select on public.daily_briefings;
create policy daily_briefings_member_select on public.daily_briefings for select to authenticated
  using (user_id = auth.uid() or public.is_dealer_member(dealer_id, array['owner','admin','manager']));
drop policy if exists briefing_items_member_select on public.briefing_items;
create policy briefing_items_member_select on public.briefing_items for select to authenticated
  using (exists (select 1 from public.daily_briefings b where b.id = briefing_id
                   and (b.user_id = auth.uid() or public.is_dealer_member(b.dealer_id, array['owner','admin','manager']))));
drop policy if exists briefing_items_owner_update on public.briefing_items;
create policy briefing_items_owner_update on public.briefing_items for update to authenticated
  using (exists (select 1 from public.daily_briefings b where b.id = briefing_id and b.user_id = auth.uid()))
  with check (exists (select 1 from public.daily_briefings b where b.id = briefing_id and b.user_id = auth.uid()));
grant update (state, acted_at) on public.briefing_items to authenticated;

-- consent ledger: staff may append evidence of in-person/verbal/e-sign consent or an opt-out; never update/delete (trigger).
drop policy if exists consent_events_staff_insert on public.consent_events;
create policy consent_events_staff_insert on public.consent_events for insert to authenticated
  with check (public.is_dealer_member(dealer_id, array['owner','admin','manager','sales','bdc'])
              and source in ('staff_entry','in_person_form','verbal_recorded','esign')
              and actor_user_id = auth.uid());
grant insert on public.consent_events to authenticated;

-- reps work the draft queue (approve/edit/discard) and the inbox; the service role does the sending.
drop policy if exists outbound_drafts_staff_update on public.outbound_drafts;
create policy outbound_drafts_staff_update on public.outbound_drafts for update to authenticated
  using (public.is_dealer_member(dealer_id, array['owner','admin','manager','sales','bdc']))
  with check (public.is_dealer_member(dealer_id, array['owner','admin','manager','sales','bdc']) and status in ('awaiting_review','held','discarded'));
grant update (body_edited, status, approved_by, approved_at) on public.outbound_drafts to authenticated;

drop policy if exists agent_inbox_staff_update on public.agent_inbox_items;
create policy agent_inbox_staff_update on public.agent_inbox_items for update to authenticated
  using (public.is_dealer_member(dealer_id, array['owner','admin','manager','sales','bdc']))
  with check (public.is_dealer_member(dealer_id, array['owner','admin','manager','sales','bdc']));
grant update (status, assigned_to, resolved_at, resolved_by) on public.agent_inbox_items to authenticated;

drop policy if exists dealer_settings_admin_update on public.dealer_settings;
create policy dealer_settings_admin_update on public.dealer_settings for update to authenticated
  using (public.is_dealer_member(dealer_id, array['owner','admin'])) with check (public.is_dealer_member(dealer_id, array['owner','admin']));
grant update on public.dealer_settings to authenticated;

-- manager rollup view inherits RLS through security_invoker
revoke all on public.v_briefing_manager_rollup from anon;
grant select on public.v_briefing_manager_rollup to authenticated;

-- Functions that touch other tenants' data or write: service role only. Pure helpers stay public.
do $grants$
declare r record;
begin
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = any (array[
              'can_send','confirm_send','release_send','record_opt_out','ai_budget_reserve','ai_budget_settle','ai_budget_status',
              'apply_lead_stage','agent_breaker_open','claim_due_drafts','handoff_stale_drafts','prune_agent_telemetry',
              'build_briefing_items','enqueue_due_briefings','claim_pending_briefings','invoke_edge_function',
              'kick_briefing_worker','kick_outbound_sweeper','consent_events_apply','messages_after_insert','dealers_seed_settings'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
end
$grants$;
grant execute on function public.is_dealer_member(uuid, text[]) to authenticated;
