-- SoldByDerek leads (Derek's own leads: phone line, social, website, referrals)
create table public.leads (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  first_name text,
  last_name text,
  phone text unique,
  email text,
  source text not null default 'phone_call'
    check (source in ('phone_call','sms','instagram','tiktok','facebook','marketplace','website','referral','other')),
  lead_type text check (lead_type in ('approval_first','shopper','trade_in','credit_help','other')),
  vehicle_interest text,
  current_vehicle text,
  down_payment_ready boolean,
  ok_to_text boolean,
  status text not null default 'new'
    check (status in ('new','contacted','appointment','showed','sold','lost')),
  appointment_at timestamptz,
  last_contact_at timestamptz,
  notes text
);

-- Every AgentPhone call
create table public.calls (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  agentphone_call_id text unique not null,
  lead_id uuid references public.leads(id) on delete set null,
  direction text,
  from_number text,
  to_number text,
  status text,
  started_at timestamptz,
  ended_at timestamptz,
  duration_seconds integer,
  transcript jsonb,
  summary text,
  outcome text,
  raw jsonb
);
create index calls_lead_id_idx on public.calls(lead_id);

-- Inbound/outbound texts on the SoldByDerek line
create table public.messages (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  agentphone_message_id text unique,
  lead_id uuid references public.leads(id) on delete set null,
  direction text,
  channel text,
  from_number text,
  to_number text,
  body text,
  raw jsonb
);
create index messages_lead_id_idx on public.messages(lead_id);

-- Dealership work stats: counts and outcomes only, NO customer PII
create table public.work_activity (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  activity_date date not null default (now() at time zone 'America/New_York')::date,
  platform text not null
    check (platform in ('vinsolutions','autoalert','autohub','phone','walk_in','other')),
  activity_type text not null
    check (activity_type in ('text','email','call','appointment_set','appointment_shown','be_back','referral','sold','note')),
  count integer not null default 1 check (count >= 0),
  notes text
);
create index work_activity_date_idx on public.work_activity(activity_date);

-- keep leads.updated_at fresh
create or replace function public.set_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at = now(); return new; end; $$;
create trigger leads_updated_at before update on public.leads
for each row execute function public.set_updated_at();

-- Lock everything down: only the service role (edge functions, Claude) can touch it
alter table public.leads enable row level security;
alter table public.calls enable row level security;
alter table public.messages enable row level security;
alter table public.work_activity enable row level security;

-- Daily scoreboard view
create view public.daily_scoreboard with (security_invoker = true) as
select activity_date,
  sum(count) filter (where activity_type='call') as calls,
  sum(count) filter (where activity_type='text') as texts,
  sum(count) filter (where activity_type='email') as emails,
  sum(count) filter (where activity_type='appointment_set') as appointments_set,
  sum(count) filter (where activity_type='appointment_shown') as appointments_shown,
  sum(count) filter (where activity_type='sold') as sold
from public.work_activity group by activity_date order by activity_date desc;