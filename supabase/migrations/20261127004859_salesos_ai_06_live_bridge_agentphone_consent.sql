-- =====================================================================================
-- Live bridge: salesos.* (accounts/users/customers/vehicles) and AgentPhone (public.leads/messages/calls) -> salesos_ai
--   * link columns only (nullable, additive); no FK onto live tables, no change to live columns/data/policies
--   * every trigger on a live table is AFTER ... and swallows its own errors (raise warning), so the live write
--     (the app, or agentphone-webhook) can never fail because of SalesOS AI
--   * Derek's consent policy: anyone who gave us their number to inquire gets a 'provided_number_inquiry' grant for
--     purpose 'inquiry_followup' (covers replies, inquiry follow-ups, appointments, test drives, transactional).
--     Marketing (blasts, re-engagement, price drops on cars they did NOT ask about) still needs express written consent.
--     STOP/opt-out, DNC, quiet hours and pacing always apply (can_send).
-- =====================================================================================
set search_path to salesos_ai, extensions, public;

-- ---------- link columns ----------
alter table salesos_ai.dealers        add column if not exists salesos_account_id text;   -- salesos.accounts.id
alter table salesos_ai.dealers        add column if not exists bridge_key text;           -- 'soldbyderek' = the AgentPhone line
alter table salesos_ai.dealer_members add column if not exists salesos_user_id text;      -- salesos.users.id
alter table salesos_ai.contacts       add column if not exists salesos_customer_id text;  -- salesos.customers.id
alter table salesos_ai.contacts       add column if not exists public_lead_id uuid;       -- public.leads.id (AgentPhone)
alter table salesos_ai.leads          add column if not exists salesos_customer_id text;
alter table salesos_ai.leads          add column if not exists public_lead_id uuid;
alter table salesos_ai.vehicles       add column if not exists salesos_vehicle_id text;   -- salesos.vehicles.id
create unique index if not exists dealers_salesos_account_uq   on salesos_ai.dealers (salesos_account_id) where salesos_account_id is not null;
create unique index if not exists dealers_bridge_key_uq        on salesos_ai.dealers (bridge_key) where bridge_key is not null;
create unique index if not exists contacts_salesos_customer_uq on salesos_ai.contacts (salesos_customer_id) where salesos_customer_id is not null;
create unique index if not exists contacts_public_lead_uq      on salesos_ai.contacts (public_lead_id) where public_lead_id is not null;
create index if not exists leads_salesos_customer_idx on salesos_ai.leads (salesos_customer_id) where salesos_customer_id is not null;
create index if not exists leads_public_lead_idx      on salesos_ai.leads (public_lead_id) where public_lead_id is not null;
create unique index if not exists vehicles_salesos_vehicle_uq on salesos_ai.vehicles (salesos_vehicle_id) where salesos_vehicle_id is not null;

-- ---------- helpers ----------
create or replace function salesos_ai.bridge_phone(p text) returns text language sql immutable set search_path = salesos_ai, pg_temp as $$
  -- same normalization as agentphone-webhook (US default), strict E.164 or null
  select case when v ~ '^\+[1-9][0-9]{6,14}$' then v end
    from (select case when d like '+%' then d
                      when length(d) = 10 then '+1' || d
                      when length(d) = 11 and d like '1%' then '+' || d
                      else null end as v
            from (select regexp_replace(coalesce(p, ''), '[^0-9+]', '', 'g') as d) a) b
$$;

create or replace function salesos_ai.bridge_stage(p text) returns text language sql immutable set search_path = salesos_ai, pg_temp as $$
  select case
    when p is null then 'new'
    when upper(p) in ('SOLD','WON','DELIVERED') then 'won'
    when upper(p) in ('APPOINTMENT','APPOINTMENT_SET','SHOWED','TEST_DRIVE') then 'test_drive'
    when upper(p) in ('NEGOTIATING','WORKING') then 'negotiating'
    when salesos_ai.lead_stage_rank(lower(p)) is not null then lower(p)
    else 'new' end
$$;

create or replace function salesos_ai.bridge_member_role(p text) returns text language sql immutable set search_path = salesos_ai, pg_temp as $$
  select case lower(coalesce(p, '')) when 'owner' then 'owner' when 'admin' then 'admin' when 'manager' then 'manager'
                                      when 'bdc' then 'bdc' when 'viewer' then 'viewer' else 'sales' end
$$;

create or replace function salesos_ai.bridge_uuid(p text) returns uuid language sql immutable set search_path = salesos_ai, pg_temp as $$
  select case when p ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then p::uuid end
$$;

create or replace function salesos_ai.bridge_ts(p text) returns timestamptz language plpgsql immutable set search_path = salesos_ai, pg_temp as $$
begin return nullif(p, '')::timestamptz; exception when others then return null; end $$;

-- ---------- tenants ----------
create or replace function salesos_ai.bridge_sync_account(p_account_id text) returns uuid
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare a salesos.accounts; v uuid; v_tz text;
begin
  select * into a from salesos.accounts where id = p_account_id;
  if a.id is null then return null; end if;
  select u.timezone into v_tz from salesos.users u where u.account_id = a.id order by (u.role = 'owner') desc, u.created_at limit 1;
  select id into v from salesos_ai.dealers where salesos_account_id = a.id;
  if v is null then
    insert into salesos_ai.dealers (name, timezone, state_code, salesos_account_id)
    values (a.name, coalesce(nullif(v_tz, ''), 'America/New_York'), 'FL', a.id) returning id into v;
  else
    update salesos_ai.dealers set name = a.name where id = v and name is distinct from a.name;
  end if;
  return v;
end $$;

create or replace function salesos_ai.bridge_sync_user(p_user_id text) returns void
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare u salesos.users; v_dealer uuid; v_uid uuid;
begin
  select * into u from salesos.users where id = p_user_id;
  v_uid := salesos_ai.bridge_uuid(u.id);
  if u.id is null or v_uid is null then return; end if;
  v_dealer := salesos_ai.bridge_sync_account(u.account_id);
  if v_dealer is null then return; end if;
  insert into salesos_ai.dealer_members (user_id, dealer_id, role, salesos_user_id)
  values (v_uid, v_dealer, salesos_ai.bridge_member_role(u.role), u.id)
  on conflict (user_id, dealer_id) do update set role = excluded.role, salesos_user_id = excluded.salesos_user_id;
end $$;

-- the AgentPhone line (SoldByDerek, +17542291849) is its own dealer, owned by the owner of the root account
create or replace function salesos_ai.bridge_agentphone_dealer() returns uuid
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare v uuid; v_owner salesos.users;
begin
  select id into v from salesos_ai.dealers where bridge_key = 'soldbyderek';
  if v is null then
    insert into salesos_ai.dealers (name, timezone, state_code, bridge_key, main_phone)
    values ('SoldByDerek', 'America/New_York', 'FL', 'soldbyderek', '+17542291849') returning id into v;
    insert into salesos_ai.channel_numbers (dealer_id, channel, provider, address, status, activated_at)
    values (v, 'sms', 'agentphone', '+17542291849', 'active', now())
    on conflict (dealer_id, channel, address) do nothing;
  end if;
  select u.* into v_owner from salesos.users u join salesos.accounts a on a.id = u.account_id
   where a.parent_account_id is null and u.role = 'owner' order by u.created_at limit 1;
  if salesos_ai.bridge_uuid(v_owner.id) is not null then
    insert into salesos_ai.dealer_members (user_id, dealer_id, role, salesos_user_id)
    values (salesos_ai.bridge_uuid(v_owner.id), v, 'owner', v_owner.id) on conflict (user_id, dealer_id) do nothing;
  end if;
  return v;
end $$;

-- ---------- consent policy ----------
-- "Anyone who gave me their number knows": one provided_number_inquiry grant per contact (sms, inquiry_followup).
-- Never re-grants over an opt-out: skipped if any sms consent state already exists or a DNC is open.
create or replace function salesos_ai.bridge_grant_provided_number(p_contact_id uuid, p_evidence jsonb) returns uuid
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare c salesos_ai.contacts; v uuid;
begin
  select * into c from salesos_ai.contacts where id = p_contact_id;
  if c.id is null or c.phone_e164 is null then return null; end if;
  if exists (select 1 from salesos_ai.contact_dnc d where d.contact_id = c.id and d.cleared_at is null and (d.channel is null or d.channel = 'sms')) then return null; end if;
  if exists (select 1 from salesos_ai.contact_consent_state s where s.contact_id = c.id and s.channel = 'sms'
               and (s.status = 'revoked' or s.purpose in ('inquiry_followup','conversational','marketing'))) then return null; end if;
  insert into salesos_ai.consent_events (dealer_id, contact_id, channel, purpose, action, source, evidence, note)
  values (c.dealer_id, c.id, 'sms', 'inquiry_followup', 'grant', 'provided_number_inquiry', coalesce(p_evidence, '{}'::jsonb),
          'Provided their number with an inquiry: replies, inquiry follow-ups, appointments, test drives. Marketing needs express written consent.')
  returning id into v;
  return v;
end $$;

-- ---------- contacts + leads ----------
create or replace function salesos_ai.bridge_upsert_contact(p_dealer_id uuid, p_phone text, p_email text, p_first text, p_last text,
  p_customer_id text default null, p_public_lead_id uuid default null, p_stage text default null, p_vehicle_id uuid default null,
  p_stage_changed boolean default false)
returns table (contact_id uuid, lead_id uuid)
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
#variable_conflict use_column
declare v_c uuid; v_l uuid; v_phone text := salesos_ai.bridge_phone(p_phone); v_email text := nullif(lower(btrim(coalesce(p_email, ''))), '');
begin
  if v_phone is null and v_email is null then return; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_dealer_id::text || ':' || coalesce(v_phone, v_email), 0));
  select c.id into v_c from salesos_ai.contacts c
   where (p_customer_id is not null and c.salesos_customer_id = p_customer_id) or (p_public_lead_id is not null and c.public_lead_id = p_public_lead_id) limit 1;
  if v_c is null then
    select c.id into v_c from salesos_ai.contacts c
     where c.dealer_id = p_dealer_id and ((v_phone is not null and c.phone_e164 = v_phone) or (v_phone is null and lower(c.email) = v_email))
     order by c.created_at limit 1;
  end if;
  if v_c is null then
    insert into salesos_ai.contacts (dealer_id, first_name, last_name, phone_e164, email, salesos_customer_id, public_lead_id)
    values (p_dealer_id, nullif(btrim(p_first), ''), nullif(btrim(p_last), ''), v_phone, v_email, p_customer_id, p_public_lead_id) returning id into v_c;
  else
    update salesos_ai.contacts c set
      first_name = coalesce(c.first_name, nullif(btrim(p_first), '')), last_name = coalesce(c.last_name, nullif(btrim(p_last), '')),
      phone_e164 = coalesce(c.phone_e164, v_phone), email = coalesce(c.email, v_email),
      salesos_customer_id = coalesce(c.salesos_customer_id, p_customer_id), public_lead_id = coalesce(c.public_lead_id, p_public_lead_id)
     where c.id = v_c;
  end if;
  select l.id into v_l from salesos_ai.leads l where l.contact_id = v_c and coalesce(l.stage, 'new') not in ('won','lost') order by l.created_at desc limit 1;
  if v_l is null then
    select l.id into v_l from salesos_ai.leads l
     where l.contact_id = v_c and ((p_customer_id is not null and l.salesos_customer_id = p_customer_id) or (p_public_lead_id is not null and l.public_lead_id = p_public_lead_id))
     order by l.created_at desc limit 1;
  end if;
  if v_l is null then
    insert into salesos_ai.leads (dealer_id, contact_id, stage, vehicle_id, salesos_customer_id, public_lead_id)
    values (p_dealer_id, v_c, coalesce(p_stage, 'new'), p_vehicle_id, p_customer_id, p_public_lead_id) returning id into v_l;
  else
    update salesos_ai.leads l set
      salesos_customer_id = coalesce(l.salesos_customer_id, p_customer_id), public_lead_id = coalesce(l.public_lead_id, p_public_lead_id),
      vehicle_id = coalesce(l.vehicle_id, p_vehicle_id),
      stage = case when p_stage_changed and p_stage is not null then p_stage else l.stage end
     where l.id = v_l;
  end if;
  contact_id := v_c; lead_id := v_l; return next;
end $$;

-- salesos.customers -> contact + lead in the account's dealer (vehicle link only for a car they asked about by VIN/stock)
create or replace function salesos_ai.bridge_sync_customer(c salesos.customers, p_stage_changed boolean default false) returns void
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare v_dealer uuid; r record; v_vehicle uuid;
begin
  v_dealer := salesos_ai.bridge_sync_account(c.account_id);
  if v_dealer is null then return; end if;
  select av.id into v_vehicle from salesos.appointments ap join salesos_ai.vehicles av on av.salesos_vehicle_id = ap.vehicle_id
   where ap.customer_id = c.id and ap.vehicle_id is not null order by ap.created_at desc limit 1;
  if v_vehicle is null and coalesce(c.vehicle_interest, '') <> '' then
    select av.id into v_vehicle from salesos.vehicles sv join salesos_ai.vehicles av on av.salesos_vehicle_id = sv.id
     where sv.account_id = c.account_id
       and ((coalesce(sv.vin, '') <> '' and position(upper(sv.vin) in upper(c.vehicle_interest)) > 0)
         or (coalesce(sv.stock_number, '') <> '' and c.vehicle_interest ~* ('(^|[^A-Za-z0-9])' || regexp_replace(sv.stock_number, '([^A-Za-z0-9])', '\\\1', 'g') || '([^A-Za-z0-9]|$)')))
     limit 1;
  end if;
  select * into r from salesos_ai.bridge_upsert_contact(v_dealer, c.phone, c.email, c.first_name, c.last_name, c.id, null,
                                                        salesos_ai.bridge_stage(c.stage), v_vehicle, p_stage_changed);
  if r.contact_id is null then return; end if;
  if c.do_not_contact = 1 then
    if not exists (select 1 from salesos_ai.contact_dnc d where d.contact_id = r.contact_id and d.cleared_at is null and d.channel is null) then
      perform salesos_ai.record_opt_out(v_dealer, r.contact_id, null, 'staff_entry', jsonb_build_object('salesos_customer_id', c.id, 'field', 'do_not_contact'), 'salesos.customers.do_not_contact = 1');
    end if;
  elsif salesos_ai.bridge_phone(c.phone) is not null then
    perform salesos_ai.bridge_grant_provided_number(r.contact_id, jsonb_build_object('salesos_customer_id', c.id, 'customer_source', c.source, 'lead_date', c.lead_date));
  end if;
end $$;

-- public.leads (AgentPhone) -> contact + lead in the SoldByDerek dealer
create or replace function salesos_ai.bridge_sync_public_lead(l public.leads, p_stage_changed boolean default false) returns void
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare v_dealer uuid := salesos_ai.bridge_agentphone_dealer(); r record;
begin
  select * into r from salesos_ai.bridge_upsert_contact(v_dealer, l.phone, l.email, l.first_name, l.last_name, null, l.id,
                                                        salesos_ai.bridge_stage(l.status), null, p_stage_changed);
  if r.contact_id is null then return; end if;
  if l.ok_to_text is false then
    if not exists (select 1 from salesos_ai.contact_dnc d where d.contact_id = r.contact_id and d.cleared_at is null and (d.channel = 'sms' or d.channel is null)) then
      perform salesos_ai.record_opt_out(v_dealer, r.contact_id, 'sms', 'staff_entry', jsonb_build_object('public_lead_id', l.id, 'field', 'ok_to_text'), 'public.leads.ok_to_text = false');
    end if;
  elsif salesos_ai.bridge_phone(l.phone) is not null then
    perform salesos_ai.bridge_grant_provided_number(r.contact_id, jsonb_build_object('public_lead_id', l.id, 'lead_source', l.source));
  end if;
end $$;

-- salesos.vehicles -> salesos_ai.vehicles (price in cents; the package trigger turns price cuts into vehicle_events)
create or replace function salesos_ai.bridge_sync_vehicle(v salesos.vehicles) returns void
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare v_dealer uuid; v_status text;
begin
  if coalesce(v.vin, '') = '' then return; end if;
  v_dealer := salesos_ai.bridge_sync_account(v.account_id);
  if v_dealer is null then return; end if;
  v_status := case when v.status = 'available' then 'available' when v.sold_at is not null and v.sold_at <> '' then 'sold'
                   when v.status in ('pending','sold','hold','in_transit') then v.status else 'hold' end;
  insert into salesos_ai.vehicles (dealer_id, vin, year, make, model, trim, price_cents, status, body_style, exterior_color, interior_color,
                                   mileage, condition, description, salesos_vehicle_id, updated_at)
  values (v_dealer, upper(v.vin), case when v.year ~ '^\d{4}$' then v.year::int end, v.make, v.model, v.trim,
          case when v.price > 0 then round(v.price * 100)::bigint end, v_status, v.body_style, v.exterior_color, v.interior_color,
          v.mileage, lower(v.condition), v.features, v.id, now())
  on conflict (dealer_id, vin) do update set
    year = excluded.year, make = excluded.make, model = excluded.model, trim = excluded.trim, price_cents = excluded.price_cents,
    status = excluded.status, body_style = excluded.body_style, exterior_color = excluded.exterior_color, interior_color = excluded.interior_color,
    mileage = excluded.mileage, condition = excluded.condition, description = excluded.description,
    salesos_vehicle_id = excluded.salesos_vehicle_id, updated_at = now();
end $$;

-- ---------- AgentPhone inbound queue (worker: agentphone-bridge Edge Function) ----------
create table if not exists salesos_ai.agentphone_inbox (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('message','call')),
  source_id uuid not null,                 -- public.messages.id / public.calls.id
  direction text,
  from_number text, to_number text,
  body text,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending','processing','done','ignored','failed')),
  attempts int not null default 0,
  locked_at timestamptz,
  last_error text,
  result jsonb,
  created_at timestamptz not null default now(),
  processed_at timestamptz,
  unique (kind, source_id)
);
create index if not exists agentphone_inbox_pending_idx on salesos_ai.agentphone_inbox (created_at) where status in ('pending','processing');
alter table salesos_ai.agentphone_inbox enable row level security;

create or replace function salesos_ai.claim_agentphone_inbox(p_limit int default 20)
returns setof salesos_ai.agentphone_inbox language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
begin
  return query
  update salesos_ai.agentphone_inbox i set status = 'processing', attempts = i.attempts + 1, locked_at = now()
   where i.id in (select x.id from salesos_ai.agentphone_inbox x
                   where (x.status = 'pending' or (x.status = 'processing' and x.locked_at < now() - interval '5 minutes')) and x.attempts < 5
                   order by x.created_at limit greatest(1, least(p_limit, 100)) for update skip locked)
  returning i.*;
end $$;

create or replace function salesos_ai.complete_agentphone_inbox(p_id uuid, p_status text, p_result jsonb default null, p_error text default null)
returns void language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
begin
  update salesos_ai.agentphone_inbox
     set status = case when p_status = 'failed' and attempts < 5 then 'pending' else p_status end,
         result = p_result, last_error = left(p_error, 1000), locked_at = null,
         processed_at = case when p_status in ('done','ignored') then now() else processed_at end
   where id = p_id;
end $$;

-- outbound AgentPhone texts (its own agent or Derek) are mirrored so pacing, spin and context see them
create or replace function salesos_ai.bridge_record_agentphone_outbound(p_inbox_id uuid) returns uuid
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare i salesos_ai.agentphone_inbox; n salesos_ai.channel_numbers; r record; v_conv uuid; v_msg uuid; v_dealer uuid := salesos_ai.bridge_agentphone_dealer();
begin
  select * into i from salesos_ai.agentphone_inbox where id = p_inbox_id;
  select * into n from salesos_ai.channel_numbers where dealer_id = v_dealer and channel = 'sms' and provider = 'agentphone' order by created_at limit 1;
  if i.id is null or n.id is null or salesos_ai.bridge_phone(i.to_number) is null then return null; end if;
  select m.id into v_msg from salesos_ai.messages m where m.channel = 'sms' and m.provider_message_id = 'agentphone:' || i.source_id::text;
  if v_msg is not null then return v_msg; end if;
  select * into r from salesos_ai.bridge_upsert_contact(v_dealer, i.to_number, null, null, null, null, null);
  insert into salesos_ai.conversations as cv (dealer_id, contact_id, number_id, channel, lead_id, last_message_at)
  values (v_dealer, r.contact_id, n.id, 'sms', r.lead_id, i.created_at)
  on conflict (dealer_id, contact_id, number_id) do update set last_message_at = greatest(cv.last_message_at, excluded.last_message_at)
  returning id into v_conv;
  insert into salesos_ai.messages (dealer_id, lead_id, contact_id, number_id, conversation_id, channel, direction, author_kind, body, provider_message_id, status, created_at)
  values (v_dealer, r.lead_id, r.contact_id, n.id, v_conv, 'sms', 'outbound', 'human', left(coalesce(i.body, ''), 4000), 'agentphone:' || i.source_id::text, 'sent', i.created_at)
  returning id into v_msg;
  update salesos_ai.leads set last_outbound_at = greatest(coalesce(last_outbound_at, '-infinity'), i.created_at) where id = r.lead_id;
  return v_msg;
end $$;

-- AgentPhone calls -> lead activity (+ opt-out screening of the summary/transcript happens in the worker)
create or replace function salesos_ai.bridge_record_agentphone_call(p_inbox_id uuid) returns jsonb
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare i salesos_ai.agentphone_inbox; r record; v_dealer uuid := salesos_ai.bridge_agentphone_dealer(); v_customer text; v_act uuid;
begin
  select * into i from salesos_ai.agentphone_inbox where id = p_inbox_id;
  if i.id is null then return null; end if;
  v_customer := case when i.direction = 'outbound' then i.to_number else i.from_number end;
  if salesos_ai.bridge_phone(v_customer) is null or salesos_ai.bridge_phone(v_customer) = '+17542291849' then return jsonb_build_object('status', 'ignored'); end if;
  select * into r from salesos_ai.bridge_upsert_contact(v_dealer, v_customer, null, null, null, null, null);
  select a.id into v_act from salesos_ai.lead_activities a where a.lead_id = r.lead_id and a.kind = 'call' and a.evidence->>'agentphone_call_row' = i.source_id::text;
  if v_act is null then
    insert into salesos_ai.lead_activities (dealer_id, lead_id, actor_kind, kind, reason, evidence, created_at)
    values (v_dealer, r.lead_id, 'system', 'call', left(coalesce(i.body, 'AgentPhone call'), 1000),
            jsonb_build_object('agentphone_call_row', i.source_id, 'direction', i.direction) || i.payload, i.created_at)
    returning id into v_act;
  end if;
  if coalesce(i.direction, 'inbound') <> 'outbound' then
    perform salesos_ai.bridge_grant_provided_number(r.contact_id, jsonb_build_object('agentphone_call_row', i.source_id, 'via', 'inbound_call'));
    update salesos_ai.leads set last_inbound_at = greatest(coalesce(last_inbound_at, '-infinity'), i.created_at) where id = r.lead_id;
  end if;
  return jsonb_build_object('status', 'done', 'dealer_id', v_dealer, 'contact_id', r.contact_id, 'lead_id', r.lead_id, 'activity_id', v_act);
end $$;

-- a STOP said on a call (or an urgent opt-out hint) - called by the worker after classifyInbound() on the call text
create or replace function salesos_ai.bridge_call_opt_out(p_inbox_id uuid, p_level text, p_matched text default null) returns jsonb
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare i salesos_ai.agentphone_inbox; v jsonb; v_lead uuid; v_contact uuid; v_dealer uuid; v_ce uuid;
begin
  select * into i from salesos_ai.agentphone_inbox where id = p_inbox_id;
  v := i.result;
  v_lead := (v->>'lead_id')::uuid; v_contact := (v->>'contact_id')::uuid; v_dealer := (v->>'dealer_id')::uuid;
  if v_contact is null then return null; end if;
  if p_level = 'stop' then
    v_ce := salesos_ai.record_opt_out(v_dealer, v_contact, null, 'verbal_recorded', jsonb_build_object('agentphone_call_row', i.source_id, 'matched', p_matched), 'Opt-out said on an AgentPhone call');
  end if;
  insert into salesos_ai.agent_inbox_items (dealer_id, lead_id, kind, priority, title, summary, payload)
  values (v_dealer, v_lead, 'needs_review', 1, case when p_level = 'stop' then 'Customer opted out on a call (all channels stopped)' else 'Call may contain an opt-out request' end,
          left(coalesce(i.body, ''), 280), jsonb_build_object('agentphone_call_row', i.source_id, 'level', p_level))
  on conflict (lead_id, kind) where status = 'open' and lead_id is not null do nothing;
  return jsonb_build_object('consent_event_id', v_ce);
end $$;

create or replace function salesos_ai.kick_agentphone_bridge() returns void language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
begin
  if exists (select 1 from salesos_ai.agentphone_inbox where (status = 'pending' or (status = 'processing' and locked_at < now() - interval '5 minutes')) and attempts < 5) then
    perform salesos_ai.invoke_edge_function('agentphone-bridge');
  end if;
end $$;

-- ---------- triggers on live tables (AFTER, error-swallowing) ----------
create or replace function salesos_ai.bridge_trg_public_leads() returns trigger
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
begin
  begin
    perform salesos_ai.bridge_sync_public_lead(new, tg_op = 'UPDATE' and old.status is distinct from new.status);
  exception when others then raise warning 'salesos_ai bridge (public.leads %): %', new.id, sqlerrm;
  end;
  return null;
end $$;

create or replace function salesos_ai.bridge_trg_public_messages() returns trigger
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
begin
  begin
    if coalesce(new.channel, 'sms') <> 'voice' then
      insert into salesos_ai.agentphone_inbox (kind, source_id, direction, from_number, to_number, body, payload, created_at)
      values ('message', new.id, coalesce(new.direction, 'inbound'), new.from_number, new.to_number, new.body,
              jsonb_build_object('agentphone_message_id', new.agentphone_message_id, 'public_lead_id', new.lead_id, 'channel', new.channel), new.created_at)
      on conflict (kind, source_id) do nothing;
      perform salesos_ai.invoke_edge_function('agentphone-bridge');
    end if;
  exception when others then raise warning 'salesos_ai bridge (public.messages %): %', new.id, sqlerrm;
  end;
  return null;
end $$;

create or replace function salesos_ai.bridge_trg_public_calls() returns trigger
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
begin
  begin
    insert into salesos_ai.agentphone_inbox (kind, source_id, direction, from_number, to_number, body, payload, created_at)
    values ('call', new.id, new.direction, new.from_number, new.to_number,
            left(concat_ws(E'\n', new.summary, case when new.transcript is not null then new.transcript::text end), 8000),
            jsonb_build_object('agentphone_call_id', new.agentphone_call_id, 'status', new.status, 'duration_seconds', new.duration_seconds, 'outcome', new.outcome), new.created_at)
    on conflict (kind, source_id) do update
       set body = excluded.body, payload = excluded.payload,
           status = case when salesos_ai.agentphone_inbox.body is distinct from excluded.body then 'pending' else salesos_ai.agentphone_inbox.status end,
           attempts = case when salesos_ai.agentphone_inbox.body is distinct from excluded.body then 0 else salesos_ai.agentphone_inbox.attempts end;
    perform salesos_ai.invoke_edge_function('agentphone-bridge');
  exception when others then raise warning 'salesos_ai bridge (public.calls %): %', new.id, sqlerrm;
  end;
  return null;
end $$;

create or replace function salesos_ai.bridge_trg_salesos_customers() returns trigger
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
begin
  begin
    perform salesos_ai.bridge_sync_customer(new, tg_op = 'UPDATE' and old.stage is distinct from new.stage);
  exception when others then raise warning 'salesos_ai bridge (salesos.customers %): %', new.id, sqlerrm;
  end;
  return null;
end $$;

create or replace function salesos_ai.bridge_trg_salesos_vehicles() returns trigger
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
begin
  begin perform salesos_ai.bridge_sync_vehicle(new);
  exception when others then raise warning 'salesos_ai bridge (salesos.vehicles %): %', new.id, sqlerrm;
  end;
  return null;
end $$;

create or replace function salesos_ai.bridge_trg_salesos_users() returns trigger
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
begin
  begin perform salesos_ai.bridge_sync_user(new.id);
  exception when others then raise warning 'salesos_ai bridge (salesos.users %): %', new.id, sqlerrm;
  end;
  return null;
end $$;

drop trigger if exists salesos_ai_bridge_trg on public.leads;
create trigger salesos_ai_bridge_trg after insert or update of phone, email, first_name, last_name, ok_to_text, status on public.leads
  for each row execute function salesos_ai.bridge_trg_public_leads();
drop trigger if exists salesos_ai_bridge_trg on public.messages;
create trigger salesos_ai_bridge_trg after insert on public.messages
  for each row execute function salesos_ai.bridge_trg_public_messages();
drop trigger if exists salesos_ai_bridge_trg on public.calls;
create trigger salesos_ai_bridge_trg after insert or update of summary, transcript on public.calls
  for each row execute function salesos_ai.bridge_trg_public_calls();
drop trigger if exists salesos_ai_bridge_trg on salesos.customers;
create trigger salesos_ai_bridge_trg after insert or update of phone, email, first_name, last_name, stage, do_not_contact, vehicle_interest on salesos.customers
  for each row execute function salesos_ai.bridge_trg_salesos_customers();
drop trigger if exists salesos_ai_bridge_trg on salesos.vehicles;
create trigger salesos_ai_bridge_trg after insert or update of vin, price, status, sold_at, year, make, model, trim, mileage on salesos.vehicles
  for each row execute function salesos_ai.bridge_trg_salesos_vehicles();
drop trigger if exists salesos_ai_bridge_trg on salesos.users;
create trigger salesos_ai_bridge_trg after insert or update of role, account_id on salesos.users
  for each row execute function salesos_ai.bridge_trg_salesos_users();

-- ---------- cron: AgentPhone worker ----------
do $$ begin
  perform cron.unschedule(jobid) from cron.job where jobname = 'salesos-agentphone-bridge';
  perform cron.schedule('salesos-agentphone-bridge', '15 seconds', $c$select salesos_ai.kick_agentphone_bridge()$c$);
end $$;

-- ---------- backfill (idempotent) ----------
do $$
declare a record; u record; v record; c record; l record;
begin
  for a in select id from salesos.accounts loop perform salesos_ai.bridge_sync_account(a.id); end loop;
  for u in select id from salesos.users loop perform salesos_ai.bridge_sync_user(u.id); end loop;
  perform salesos_ai.bridge_agentphone_dealer();
  for v in select * from salesos.vehicles loop
    begin perform salesos_ai.bridge_sync_vehicle(v); exception when others then raise warning 'vehicle %: %', v.id, sqlerrm; end;
  end loop;
  for c in select * from salesos.customers where duplicate_of is null order by created_at loop
    begin perform salesos_ai.bridge_sync_customer(c, false); exception when others then raise warning 'customer %: %', c.id, sqlerrm; end;
  end loop;
  for l in select * from public.leads loop
    begin perform salesos_ai.bridge_sync_public_lead(l, false); exception when others then raise warning 'lead %: %', l.id, sqlerrm; end;
  end loop;
end $$;

-- ---------- hardening ----------
do $$
declare r record;
begin
  -- pin search_path on every salesos_ai function that lacks one
  for r in select p.oid::regprocedure as sig from pg_proc p
            where p.pronamespace = 'salesos_ai'::regnamespace and p.prokind = 'f'
              and not exists (select 1 from unnest(coalesce(p.proconfig, '{}')) cfg where cfg like 'search_path=%') loop
    execute format('alter function %s set search_path = salesos_ai, extensions, pg_temp', r.sig);
  end loop;
  -- RLS on every table; the app role (salesos_app) gets read-only visibility, service_role bypasses RLS
  for r in select c.oid::regclass as t from pg_class c where c.relnamespace = 'salesos_ai'::regnamespace and c.relkind in ('r','p') loop
    execute format('alter table %s enable row level security', r.t);
    if not exists (select 1 from pg_policies where schemaname = 'salesos_ai' and tablename = split_part(r.t::text, '.', 2) and policyname = 'salesos_app_read') then
      execute format('create policy salesos_app_read on %s for select to salesos_app using (true)', r.t);
    end if;
  end loop;
end $$;
grant all on all tables in schema salesos_ai to service_role;
grant all on all sequences in schema salesos_ai to service_role;
grant execute on all functions in schema salesos_ai to service_role;
grant select on all tables in schema salesos_ai to salesos_app;
