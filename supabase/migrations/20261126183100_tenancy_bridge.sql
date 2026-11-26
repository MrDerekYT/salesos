-- =====================================================================================
-- Tenancy bridge: maps the original single-user SalesOS model onto the dealer (tenant) model
-- the consent / agent / briefing migrations use.
--
--   profiles (auth.users)  -> each user gets a personal "dealer" workspace (dealers.owner_user_id)
--                             and a dealer_members row with role 'owner'.
--   leads.user_id          -> kept. leads gain dealer_id, contact_id, assigned_to, value_cents.
--   leads.name/email/phone -> a contacts row per lead (phone normalised to E.164 when possible).
--   leads.value (dollars)  -> leads.value_cents kept in sync by trigger.
--
-- Existing app code that inserts leads with only user_id/name/email/phone keeps working:
-- a BEFORE INSERT trigger fills dealer_id, contact_id and assigned_to.
-- Idempotent.
-- =====================================================================================

create table if not exists public.dealers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  timezone text not null default 'America/New_York',
  state_code char(2),
  created_at timestamptz not null default now()
);
alter table public.dealers add column if not exists owner_user_id uuid references auth.users(id) on delete set null;
alter table public.dealers add column if not exists is_personal boolean not null default false;
create unique index if not exists dealers_personal_owner_uq on public.dealers (owner_user_id) where is_personal;

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

alter table public.leads add column if not exists dealer_id uuid references public.dealers(id) on delete cascade;
alter table public.leads add column if not exists contact_id uuid references public.contacts(id) on delete cascade;
alter table public.leads add column if not exists assigned_to uuid;
alter table public.leads add column if not exists value_cents bigint;
create index if not exists leads_user_idx on public.leads (user_id);
create index if not exists leads_contact_idx on public.leads (contact_id);

-- ---------- helpers ----------
create or replace function public.normalize_phone_e164(p text) returns text language sql immutable as $$
  select case
    when p is null then null
    when regexp_replace(p, '\D', '', 'g') ~ '^\d{10}$' and left(btrim(p), 1) <> '+' then '+1' || regexp_replace(p, '\D', '', 'g')
    when regexp_replace(p, '\D', '', 'g') ~ '^1\d{10}$' then '+' || regexp_replace(p, '\D', '', 'g')
    when left(btrim(p), 1) = '+' and regexp_replace(p, '\D', '', 'g') ~ '^\d{8,15}$' then '+' || regexp_replace(p, '\D', '', 'g')
    else null end
$$;

-- Map the dashboard's display stages onto the pipeline stages the agent understands.
create or replace function public.normalize_lead_stage(p text) returns text language sql immutable as $$
  select case lower(regexp_replace(btrim(coalesce(p, '')), '[\s-]+', '_', 'g'))
    when '' then 'new' when 'lead_in' then 'new' when 'lead' then 'new'
    when 'proposal' then 'negotiating' when 'negotiation' then 'negotiating'
    when 'closed_won' then 'won' when 'closed_lost' then 'lost'
    when 'test_drive_scheduled' then 'test_drive'
    else lower(regexp_replace(btrim(p), '[\s-]+', '_', 'g')) end
$$;

-- Returns (creating on first use) the personal dealer workspace for a user.
create or replace function public.ensure_personal_dealer(p_user_id uuid)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid; v_name text;
begin
  if p_user_id is null then return null; end if;
  select id into v_id from public.dealers where owner_user_id = p_user_id and is_personal;
  if v_id is null then
    select coalesce(nullif(btrim(full_name), ''), nullif(btrim(email), ''), 'My dealership') into v_name
      from public.profiles where id = p_user_id;
    insert into public.dealers (name, owner_user_id, is_personal)
    values (coalesce(v_name, 'My dealership'), p_user_id, true)
    on conflict (owner_user_id) where is_personal do nothing
    returning id into v_id;
    if v_id is null then
      select id into v_id from public.dealers where owner_user_id = p_user_id and is_personal;
    end if;
  end if;
  insert into public.dealer_members (user_id, dealer_id, role) values (p_user_id, v_id, 'owner')
  on conflict (user_id, dealer_id) do nothing;
  return v_id;
end $$;
revoke all on function public.ensure_personal_dealer(uuid) from public, anon, authenticated;

-- ---------- leads: fill tenant/contact/value columns on write ----------
create or replace function public.leads_bridge_fill() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_first text; v_last text;
begin
  if tg_op = 'INSERT' then
    if new.user_id is null and new.dealer_id is null and auth.uid() is not null
       and exists (select 1 from public.profiles where id = auth.uid()) then
      new.user_id := auth.uid();
    end if;
    if new.dealer_id is null and new.user_id is not null then
      new.dealer_id := public.ensure_personal_dealer(new.user_id);
    end if;
    if new.assigned_to is null then new.assigned_to := new.user_id; end if;
    new.stage := public.normalize_lead_stage(new.stage);
    if new.contact_id is null and new.dealer_id is not null then
      v_first := nullif(split_part(btrim(coalesce(new.name, '')), ' ', 1), '');
      v_last  := nullif(btrim(substr(btrim(coalesce(new.name, '')), length(coalesce(v_first, '')) + 1)), '');
      insert into public.contacts (dealer_id, first_name, last_name, phone_e164, email)
      values (new.dealer_id, v_first, v_last, public.normalize_phone_e164(new.phone), nullif(btrim(lower(new.email)), ''))
      returning id into new.contact_id;
    end if;
    if new.value_cents is null and new.value is not null then new.value_cents := round(new.value * 100); end if;
  else
    if new.stage is distinct from old.stage then new.stage := public.normalize_lead_stage(new.stage); end if;
    if new.value is distinct from old.value and new.value_cents is not distinct from old.value_cents then
      new.value_cents := round(coalesce(new.value, 0) * 100);
    elsif new.value_cents is distinct from old.value_cents and new.value is not distinct from old.value then
      new.value := coalesce(new.value_cents, 0) / 100.0;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists leads_bridge_fill_trg on public.leads;
create trigger leads_bridge_fill_trg before insert or update on public.leads
  for each row execute function public.leads_bridge_fill();

-- new signups get their workspace immediately
create or replace function public.profiles_ensure_dealer() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin perform public.ensure_personal_dealer(new.id); return new; end $$;
drop trigger if exists profiles_ensure_dealer_trg on public.profiles;
create trigger profiles_ensure_dealer_trg after insert on public.profiles
  for each row execute function public.profiles_ensure_dealer();

-- ---------- backfill existing data ----------
do $bf$
declare r record; v_orphan uuid; v_cid uuid; v_first text;
begin
  perform public.ensure_personal_dealer(p.id) from public.profiles p;

  update public.leads set dealer_id = public.ensure_personal_dealer(user_id)
   where dealer_id is null and user_id is not null;

  -- leads with no owner go to one shared "Unassigned (migrated)" workspace (no members; service role only)
  if exists (select 1 from public.leads where dealer_id is null) then
    select id into v_orphan from public.dealers where name = 'Unassigned (migrated)' and owner_user_id is null limit 1;
    if v_orphan is null then
      insert into public.dealers (name) values ('Unassigned (migrated)') returning id into v_orphan;
    end if;
    update public.leads set dealer_id = v_orphan where dealer_id is null;
  end if;

  for r in select id, dealer_id, name, email, phone from public.leads where contact_id is null loop
    v_first := nullif(split_part(btrim(coalesce(r.name, '')), ' ', 1), '');
    insert into public.contacts (dealer_id, first_name, last_name, phone_e164, email)
    values (r.dealer_id, v_first,
            nullif(btrim(substr(btrim(coalesce(r.name, '')), length(coalesce(v_first, '')) + 1)), ''),
            public.normalize_phone_e164(r.phone), nullif(btrim(lower(r.email)), ''))
    returning id into v_cid;
    update public.leads set contact_id = v_cid where id = r.id;
  end loop;

  update public.leads set created_at = now() where created_at is null;
  update public.leads set assigned_to = user_id where assigned_to is null and user_id is not null;
  update public.leads set value_cents = round(value * 100) where value_cents is null and value is not null;
  update public.leads set stage = public.normalize_lead_stage(stage)
   where stage is null or stage is distinct from public.normalize_lead_stage(stage);
end $bf$;

alter table public.leads alter column dealer_id set not null;
alter table public.leads alter column contact_id set not null;
alter table public.leads alter column stage set default 'new';
alter table public.leads alter column stage set not null;
alter table public.leads alter column created_at set not null;

-- pg_net powers the cron -> Edge Function dispatch. Supabase ships it; skip quietly where unavailable.
do $ext$ begin
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_net;
  end if;
end $ext$;
