-- =====================================================================================
-- SalesOS phase 3: hybrid RAG with citations | follow-up engine + sweeper support |
--                  reply classification + automatic pipeline moves | CRM by text + MCP |
--                  gap fixes (injectable clock, per-dealer briefing config)
-- Requires 20261126170000_consent_agent_briefing.sql. Postgres 15+ with pgvector >= 0.7 (tested: PG 17, pgvector 0.8).
-- Idempotent: safe to run twice.
--
-- Pattern attributions (ideas only; all code here is original):
--   * wacrm (ArnasDon/wacrm, MIT): knowledge table + hybrid search, re-embed on change.
--   * AgentSDR (Kandid-ai/AgentSDR, MIT): confidence-gated stage moves, draft citations, review queue.
--   * DeskcommCRM (melgarafael/DeskcommCRM, MIT): silence sweep / promise keeping, attempt caps.
--   * Atomic CRM (marmelab/atomic-crm, MIT): CRM tools exposed over MCP from a Supabase Edge Function.
-- =====================================================================================

-- pgvector: Supabase installs extensions into schema "extensions"; plain Postgres uses public.
do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'extensions') then
    execute 'create extension if not exists vector with schema extensions';
  else
    execute 'create extension if not exists vector';
  end if;
exception when others then
  raise exception 'pgvector is required for phase 3 (kb_chunks.embedding vector(1536)): %', sqlerrm;
end $$;
set search_path to public, extensions;

-- =====================================================================================
-- PART F. GAP FIXES: injectable clock + per-dealer briefing config
-- =====================================================================================
-- app_now(): now(), unless the transaction/session sets salesos.now. build_briefing_items() pins it to its p_now
-- so the candidate views and the scorer agree on one instant (fixes the "test_drive_today near midnight" flake),
-- and tests can freeze time without touching data. Only affects reads; every write path still takes p_now.
create or replace function public.app_now() returns timestamptz language sql stable as $$
  select coalesce(nullif(current_setting('salesos.now', true), '')::timestamptz, now())
$$;

-- per-dealer overrides; any NULL column falls back to the global briefing_kind_config row
create table if not exists public.dealer_briefing_kind_config (
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  kind public.briefing_item_kind not null,
  enabled boolean not null default true,
  weight numeric check (weight is null or weight between 0 and 1),
  ramp_hours numeric check (ramp_hours is null or ramp_hours >= 0),
  grace_hours numeric check (grace_hours is null or grace_hours >= 0),
  half_life_hours numeric check (half_life_hours is null or half_life_hours > 0),
  updated_at timestamptz not null default now(),
  primary key (dealer_id, kind)
);

create or replace function public.briefing_kind_cfg(p_dealer_id uuid, p_kind public.briefing_item_kind)
returns table (enabled boolean, weight numeric, ramp_hours numeric, grace_hours numeric, half_life_hours numeric)
language sql stable as $$
  select coalesce(d.enabled, true), coalesce(d.weight, g.weight), coalesce(d.ramp_hours, g.ramp_hours),
         coalesce(d.grace_hours, g.grace_hours), coalesce(d.half_life_hours, g.half_life_hours)
    from public.briefing_kind_config g
    left join public.dealer_briefing_kind_config d on d.kind = g.kind and d.dealer_id = p_dealer_id
   where g.kind = p_kind
$$;

-- scorer now takes the dealer (old 5-arg overload removed so calls are unambiguous)
drop function if exists public.briefing_score(public.briefing_item_kind, timestamptz, bigint, boolean, timestamptz);
create or replace function public.briefing_score(p_kind public.briefing_item_kind, p_event_at timestamptz,
  p_value_cents bigint, p_reachable boolean, p_now timestamptz default public.app_now(), p_dealer_id uuid default null)
returns table (score numeric, parts jsonb) language plpgsql stable as $$
declare cfg record; age_h numeric; v_ramp numeric; v_decay numeric; v_value numeric; v_reach numeric;
begin
  select * into cfg from public.briefing_kind_cfg(p_dealer_id, p_kind);
  age_h   := greatest(0, extract(epoch from (p_now - p_event_at)) / 3600.0);
  v_ramp  := case when cfg.ramp_hours > 0 then least(1, 0.4 + 0.6 * age_h / cfg.ramp_hours) else 1 end;
  v_decay := power(0.5, greatest(0, age_h - cfg.grace_hours) / cfg.half_life_hours);
  v_value := 0.5 + 0.5 * least(1, ln(1 + coalesce(p_value_cents, 0) / 100.0) / ln(1 + 50000));
  v_reach := case when p_reachable then 1 else 0.6 end;
  score := round(cfg.weight * v_value * v_ramp * v_decay * v_reach, 6);
  parts := jsonb_build_object('weight', cfg.weight, 'value', round(v_value, 4), 'ramp', round(v_ramp, 4),
                              'decay', round(v_decay, 4), 'reach', v_reach, 'age_h', round(age_h, 2),
                              'config', case when exists (select 1 from public.dealer_briefing_kind_config d where d.dealer_id = p_dealer_id and d.kind = p_kind) then 'dealer' else 'global' end);
  return next;
end $$;

-- candidate views on the injectable clock (same columns => dependants stay valid)
create or replace view public.v_cand_waiting_reply with (security_invoker = true) as
select l.dealer_id, l.id as lead_id, l.assigned_to as owner_user_id, 'waiting_reply'::public.briefing_item_kind as kind,
       l.last_inbound_at as event_at, l.value_cents,
       jsonb_build_object('last_inbound_at', l.last_inbound_at) as evidence
  from public.leads l
 where l.stage not in ('won','lost') and l.last_inbound_at is not null
   and l.last_inbound_at > coalesce(l.last_outbound_at, '-infinity'::timestamptz)
   and l.last_inbound_at < public.app_now() - interval '10 minutes';

create or replace view public.v_cand_test_drive_today with (security_invoker = true) as
select a.dealer_id, a.lead_id, l.assigned_to, 'test_drive_today'::public.briefing_item_kind,
       a.starts_at, l.value_cents,
       jsonb_build_object('appointment_id', a.id, 'starts_at', a.starts_at, 'kind', a.kind, 'status', a.status, 'vehicle_id', a.vehicle_id)
  from public.appointments a
  join public.leads l on l.id = a.lead_id
  join public.dealers d on d.id = a.dealer_id
 where a.kind in ('test_drive','showroom') and a.status in ('requested','confirmed')
   and (a.starts_at at time zone d.timezone)::date = (public.app_now() at time zone d.timezone)::date
   and a.starts_at >= public.app_now() - interval '30 minutes';

create or replace view public.v_cand_test_drive_noshow with (security_invoker = true) as
select a.dealer_id, a.lead_id, l.assigned_to, 'test_drive_noshow'::public.briefing_item_kind,
       a.starts_at, l.value_cents,
       jsonb_build_object('appointment_id', a.id, 'starts_at', a.starts_at, 'status', a.status, 'vehicle_id', a.vehicle_id)
  from public.appointments a
  join public.leads l on l.id = a.lead_id
 where a.kind in ('test_drive','showroom') and l.stage not in ('won','lost')
   and (a.status = 'no_show' or (a.status in ('requested','confirmed') and a.starts_at < public.app_now() - interval '45 minutes'))
   and a.starts_at > public.app_now() - interval '36 hours';

create or replace view public.v_cand_callback_due with (security_invoker = true) as
select f.dealer_id, f.lead_id, coalesce(f.assigned_to, l.assigned_to), 'callback_due'::public.briefing_item_kind,
       f.due_at, l.value_cents,
       jsonb_build_object('followup_id', f.id, 'followup_kind', f.kind, 'reason', f.reason, 'promised_text', f.promised_text)
  from public.followups f
  join public.leads l on l.id = f.lead_id
 where f.status in ('scheduled','due') and f.due_at <= public.app_now() and l.stage not in ('won','lost');

create or replace view public.v_cand_hot_gone_quiet with (security_invoker = true) as
select l.dealer_id, l.id, l.assigned_to, 'hot_gone_quiet'::public.briefing_item_kind,
       greatest(coalesce(l.last_inbound_at, l.created_at), coalesce(l.last_outbound_at, l.created_at)) as event_at, l.value_cents,
       jsonb_build_object('stage', l.stage,
                          'views_7d', (select count(*) from public.lead_vehicle_views v where v.lead_id = l.id and v.viewed_at > public.app_now() - interval '7 days')) as evidence
  from public.leads l
 where l.stage in ('qualified','test_drive','negotiating')
   and greatest(coalesce(l.last_inbound_at, l.created_at), coalesce(l.last_outbound_at, l.created_at)) < public.app_now() - interval '72 hours'
   and greatest(coalesce(l.last_inbound_at, l.created_at), coalesce(l.last_outbound_at, l.created_at)) > public.app_now() - interval '21 days'
   and not exists (select 1 from public.followups f where f.lead_id = l.id and f.status in ('scheduled','due'));

create or replace view public.v_cand_price_drop_viewed with (security_invoker = true) as
select distinct on (l.id, e.vehicle_id)
       l.dealer_id, l.id, l.assigned_to, 'price_drop_viewed'::public.briefing_item_kind,
       e.changed_at, l.value_cents,
       jsonb_build_object('vehicle_id', e.vehicle_id, 'vin', v.vin, 'old_price_cents', e.old_price_cents,
                          'new_price_cents', e.new_price_cents, 'drop_cents', e.old_price_cents - e.new_price_cents)
  from public.vehicle_price_events e
  join public.vehicles v on v.id = e.vehicle_id and v.status = 'available'
  join public.lead_vehicle_views lv on lv.vehicle_id = e.vehicle_id and lv.viewed_at > public.app_now() - interval '30 days'
  join public.leads l on l.id = lv.lead_id and l.dealer_id = e.dealer_id
 where e.new_price_cents < e.old_price_cents and e.changed_at > public.app_now() - interval '48 hours'
   and l.stage not in ('won','lost')
 order by l.id, e.vehicle_id, e.changed_at desc;

create or replace view public.v_cand_trade_in_pending with (security_invoker = true) as
select t.dealer_id, t.lead_id, l.assigned_to, 'trade_in_pending'::public.briefing_item_kind,
       t.requested_at, l.value_cents,
       jsonb_build_object('appraisal_id', t.id, 'status', t.status, 'year', t.year, 'make', t.make, 'model', t.model)
  from public.trade_in_appraisals t
  join public.leads l on l.id = t.lead_id
 where t.status in ('requested','in_review') and t.requested_at < public.app_now() - interval '4 hours' and l.stage not in ('won','lost');

create or replace view public.v_cand_lease_ending with (security_invoker = true) as
select l.dealer_id, l.id, l.assigned_to, 'lease_ending'::public.briefing_item_kind,
       (l.lease_end_on - 90)::timestamptz as event_at, l.value_cents,
       jsonb_build_object('lease_end_on', l.lease_end_on, 'days_left', l.lease_end_on - (public.app_now() at time zone d.timezone)::date)
  from public.leads l join public.dealers d on d.id = l.dealer_id
 where l.lease_end_on is not null
   and l.lease_end_on between (public.app_now() at time zone d.timezone)::date and (public.app_now() at time zone d.timezone)::date + 90
   and l.stage not in ('won','lost');

create or replace function public.briefing_reason_text(p_kind public.briefing_item_kind, p_evidence jsonb, p_event_at timestamptz, p_now timestamptz default public.app_now())
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

-- build: pins the clock to p_now, uses per-dealer config, skips kinds a dealer disabled
create or replace function public.build_briefing_items(p_briefing_id uuid, p_now timestamptz default public.app_now())
returns int language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare b public.daily_briefings; v_role text; v_size int; v_n int; v_total int; v_by jsonb; v_old_clock text;
begin
  select * into b from public.daily_briefings where id = p_briefing_id for update;
  if b.id is null then raise exception 'briefing % not found', p_briefing_id; end if;
  if b.status = 'delivered' then return 0; end if;
  v_old_clock := current_setting('salesos.now', true);
  perform set_config('salesos.now', p_now::text, true);           -- views below see exactly p_now

  select m.role::text into v_role from public.dealer_members m where m.user_id = b.user_id and m.dealer_id = b.dealer_id;
  select briefing_size into v_size from public.dealer_settings where dealer_id = b.dealer_id;
  delete from public.briefing_items where briefing_id = b.id;

  drop table if exists _cands;
  create temp table _cands on commit drop as
  select c.*, s.score, s.parts,
         array_agg(c.kind) over (partition by c.lead_id) as all_kinds
    from public.briefing_candidates c
    cross join lateral public.briefing_kind_cfg(b.dealer_id, c.kind) k
    cross join lateral public.briefing_score(c.kind, c.event_at, c.value_cents, c.contact_reachable, p_now, b.dealer_id) s
   where c.dealer_id = b.dealer_id and k.enabled
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
  perform set_config('salesos.now', coalesce(v_old_clock, ''), true);
  return v_n;
end $$;

-- =====================================================================================
-- PART G. HYBRID RAG WITH CITATIONS (feature 4)
-- =====================================================================================
-- Facts that change (price, availability, APR) are NEVER embedded: they come from check_inventory / quote tools.
alter table public.vehicles add column if not exists body_style text;
alter table public.vehicles add column if not exists exterior_color text;
alter table public.vehicles add column if not exists interior_color text;
alter table public.vehicles add column if not exists mileage int;
alter table public.vehicles add column if not exists condition text;          -- new | used | cpo
alter table public.vehicles add column if not exists features text[];
alter table public.vehicles add column if not exists description text;

create table if not exists public.kb_documents (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  kind text not null check (kind in ('faq','financing','trade_in','policy','incentive','objection','scheduling','vehicle_description')),
  title text not null,
  body text not null,
  source_uri text,                                           -- where a rep can verify it (PDF, page, DMS doc)
  status text not null default 'active' check (status in ('draft','active','archived')),
  valid_from timestamptz, valid_until timestamptz,           -- incentives expire: expired docs are never retrieved
  version int not null default 1,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (valid_until is null or valid_from is null or valid_until > valid_from)
);
create index if not exists kb_documents_dealer_idx on public.kb_documents (dealer_id, kind) where status = 'active';

create table if not exists public.kb_chunks (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  document_id uuid not null references public.kb_documents(id) on delete cascade,
  chunk_index int not null check (chunk_index >= 0),
  heading text,
  content text not null,
  content_hash text not null,
  embedding vector(1536),
  embedding_model text,
  embedded_at timestamptz,
  fts tsvector generated always as (
    setweight(to_tsvector('english'::regconfig, coalesce(heading, '')), 'A') ||
    setweight(to_tsvector('english'::regconfig, content), 'B')) stored,
  created_at timestamptz not null default now(),
  unique (document_id, chunk_index)
);
create index if not exists kb_chunks_dealer_idx on public.kb_chunks (dealer_id);
create index if not exists kb_chunks_fts_idx on public.kb_chunks using gin (fts);
create index if not exists kb_chunks_embedding_hnsw on public.kb_chunks using hnsw (embedding vector_cosine_ops);

create table if not exists public.vehicle_listing_chunks (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  vehicle_id uuid not null unique references public.vehicles(id) on delete cascade,
  content text not null,                                     -- descriptive only: no price, no status
  content_hash text not null,
  embedding vector(1536),
  embedding_model text,
  embedded_at timestamptz,
  fts tsvector generated always as (to_tsvector('english'::regconfig, content)) stored,
  updated_at timestamptz not null default now()
);
create index if not exists vehicle_listing_chunks_dealer_idx on public.vehicle_listing_chunks (dealer_id);
create index if not exists vehicle_listing_chunks_fts_idx on public.vehicle_listing_chunks using gin (fts);
create index if not exists vehicle_listing_chunks_hnsw on public.vehicle_listing_chunks using hnsw (embedding vector_cosine_ops);

-- re-embed queue (one row per target; re-enqueue resets it)
create table if not exists public.embed_queue (
  target_kind text not null check (target_kind in ('kb_chunk','vehicle_chunk')),
  target_id uuid not null,
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  reason text,
  enqueued_at timestamptz not null default now(),
  not_before timestamptz not null default now(),
  attempts int not null default 0,
  locked_at timestamptz,
  last_error text,
  primary key (target_kind, target_id)
);
create index if not exists embed_queue_due_idx on public.embed_queue (not_before) where locked_at is null;

create or replace function public.enqueue_embedding(p_kind text, p_id uuid, p_dealer_id uuid, p_reason text)
returns void language sql security definer set search_path = public, pg_temp as $$
  insert into public.embed_queue (target_kind, target_id, dealer_id, reason)
  values (p_kind, p_id, p_dealer_id, p_reason)
  on conflict (target_kind, target_id) do update
     set reason = excluded.reason, enqueued_at = now(), not_before = now(), attempts = 0, last_error = null
$$;

-- deterministic paragraph/sentence chunker (~p_max chars). Lives in SQL so full-text search works with no worker at all.
create or replace function public.kb_chunk_text(p_body text, p_max int default 1200)
returns table (idx int, content text) language plpgsql immutable as $$
declare para text; piece text; buf text := ''; i int := 0;
begin
  for para in select btrim(x) from regexp_split_to_table(coalesce(p_body, ''), E'\\n\\s*\\n') with ordinality t(x, o) order by o loop
    continue when para = '';
    for piece in
      select btrim(s) from regexp_split_to_table(para, case when length(para) > p_max then '(?<=[.!?])\s+' else '\a\a\a' end) with ordinality u(s, o) order by o
    loop
      continue when piece = '';
      while length(piece) > p_max loop                       -- one giant sentence: hard cut
        if buf <> '' then idx := i; content := buf; return next; i := i + 1; buf := ''; end if;
        idx := i; content := left(piece, p_max); return next; i := i + 1;
        piece := btrim(substr(piece, p_max + 1));
      end loop;
      if buf <> '' and length(buf) + 1 + length(piece) > p_max then
        idx := i; content := buf; return next; i := i + 1; buf := piece;
      else
        buf := case when buf = '' then piece else buf || E'\n' || piece end;
      end if;
    end loop;
  end loop;
  if buf <> '' then idx := i; content := buf; return next; end if;
end $$;

create or replace function public.kb_rechunk(p_document_id uuid) returns int
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare d public.kb_documents; v_n int; v_changed int;
begin
  select * into d from public.kb_documents where id = p_document_id;
  if d.id is null then return 0; end if;
  with src as (select c.idx, c.content, md5(coalesce(d.title,'') || E'\x1f' || c.content) as h from public.kb_chunk_text(d.body) c),
       up as (
         insert into public.kb_chunks (dealer_id, document_id, chunk_index, heading, content, content_hash)
         select d.dealer_id, d.id, s.idx, d.title, s.content, s.h from src s
         on conflict (document_id, chunk_index) do update
            set heading = excluded.heading, content = excluded.content, content_hash = excluded.content_hash,
                embedding = null, embedding_model = null, embedded_at = null
          where public.kb_chunks.content_hash is distinct from excluded.content_hash
         returning id),
       q as (select public.enqueue_embedding('kb_chunk', up.id, d.dealer_id, 'content_changed') from up)
  select count(*) into v_changed from q;
  select count(*) into v_n from public.kb_chunk_text(d.body);
  delete from public.kb_chunks where document_id = d.id and chunk_index >= v_n;
  return v_changed;
end $$;

create or replace function public.kb_documents_after_write() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' or new.body is distinct from old.body or new.title is distinct from old.title then
    perform public.kb_rechunk(new.id);
  end if;
  return new;
end $$;
drop trigger if exists kb_documents_after_write_trg on public.kb_documents;
create trigger kb_documents_after_write_trg after insert or update of body, title on public.kb_documents
  for each row execute function public.kb_documents_after_write();

create or replace function public.kb_documents_bump_version() returns trigger language plpgsql as $$
begin
  if new.body is distinct from old.body or new.title is distinct from old.title then
    new.version := old.version + 1;
  end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists kb_documents_bump_version_trg on public.kb_documents;
create trigger kb_documents_bump_version_trg before update on public.kb_documents
  for each row execute function public.kb_documents_bump_version();

-- descriptive listing text: deliberately excludes price and status (those go stale; tools own them)
create or replace function public.vehicle_listing_text(v public.vehicles) returns text language sql immutable as $$
  select concat_ws(E'\n',
    nullif(concat_ws(' ', v.year::text, v.make, v.model, v.trim), ''),
    'VIN ' || v.vin,
    nullif(concat_ws(' | ',
      'Body: ' || v.body_style,
      'Condition: ' || v.condition,
      'Color: ' || concat_ws(' / ', v.exterior_color, v.interior_color || ' interior'),
      'Mileage: ' || to_char(v.mileage, 'FM999,999,999')), ''),
    'Features: ' || nullif(array_to_string(v.features, ', '), ''),
    v.description)
$$;

create or replace function public.vehicles_sync_listing_chunk() returns trigger
language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v_text text := public.vehicle_listing_text(new); v_id uuid;
begin
  insert into public.vehicle_listing_chunks (dealer_id, vehicle_id, content, content_hash)
  values (new.dealer_id, new.id, v_text, md5(v_text))
  on conflict (vehicle_id) do update
     set content = excluded.content, content_hash = excluded.content_hash, updated_at = now(),
         embedding = null, embedding_model = null, embedded_at = null
   where public.vehicle_listing_chunks.content_hash is distinct from excluded.content_hash
  returning id into v_id;
  if v_id is not null then
    perform public.enqueue_embedding('vehicle_chunk', v_id, new.dealer_id, case when tg_op = 'INSERT' then 'vehicle_added' else 'vehicle_changed' end);
  end if;
  return new;
end $$;
drop trigger if exists vehicles_sync_listing_chunk_trg on public.vehicles;
create trigger vehicles_sync_listing_chunk_trg after insert or update on public.vehicles
  for each row execute function public.vehicles_sync_listing_chunk();
-- backfill existing inventory (no-op on re-run: hashes match)
update public.vehicles set updated_at = updated_at where not exists (select 1 from public.vehicle_listing_chunks c where c.vehicle_id = vehicles.id);

-- worker API: claim -> embed -> complete (hash-checked) | fail (backoff) | defer (no provider configured)
create or replace function public.claim_embed_jobs(p_limit int default 64, p_now timestamptz default now())
returns table (target_kind text, target_id uuid, dealer_id uuid, content text, content_hash text, attempts int)
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  return query
  with c as (
    update public.embed_queue q set locked_at = p_now, attempts = q.attempts + 1
     where (q.target_kind, q.target_id) in (
       select e.target_kind, e.target_id from public.embed_queue e
        where e.not_before <= p_now and (e.locked_at is null or e.locked_at < p_now - interval '10 minutes') and e.attempts < 8
        order by e.enqueued_at for update skip locked limit greatest(1, least(p_limit, 256)))
    returning q.target_kind, q.target_id, q.dealer_id, q.attempts)
  select c.target_kind, c.target_id, c.dealer_id,
         coalesce(k.heading || E'\n' || k.content, k.content, v.content),
         coalesce(k.content_hash, v.content_hash), c.attempts
    from c
    left join public.kb_chunks k on c.target_kind = 'kb_chunk' and k.id = c.target_id
    left join public.vehicle_listing_chunks v on c.target_kind = 'vehicle_chunk' and v.id = c.target_id;
end $$;

create or replace function public.complete_embed_job(p_kind text, p_id uuid, p_embedding vector(1536), p_model text,
  p_content_hash text, p_now timestamptz default now())
returns text language plpgsql security definer set search_path = public, extensions, pg_temp as $$
declare v_ok boolean := false; v_exists boolean;
begin
  if p_kind = 'kb_chunk' then
    update public.kb_chunks set embedding = p_embedding, embedding_model = p_model, embedded_at = p_now
     where id = p_id and content_hash = p_content_hash returning true into v_ok;
    v_exists := exists (select 1 from public.kb_chunks where id = p_id);
  elsif p_kind = 'vehicle_chunk' then
    update public.vehicle_listing_chunks set embedding = p_embedding, embedding_model = p_model, embedded_at = p_now
     where id = p_id and content_hash = p_content_hash returning true into v_ok;
    v_exists := exists (select 1 from public.vehicle_listing_chunks where id = p_id);
  else
    raise exception 'unknown target kind %', p_kind;
  end if;
  if coalesce(v_ok, false) then
    delete from public.embed_queue where target_kind = p_kind and target_id = p_id;   -- hash matched: this vector is current
    return 'stored';
  elsif v_exists then
    update public.embed_queue set locked_at = null where target_kind = p_kind and target_id = p_id;
    return 'stale';
  else
    delete from public.embed_queue where target_kind = p_kind and target_id = p_id;
    return 'missing';
  end if;
end $$;

create or replace function public.fail_embed_job(p_kind text, p_id uuid, p_error text, p_now timestamptz default now())
returns void language sql security definer set search_path = public, pg_temp as $$
  update public.embed_queue
     set locked_at = null, last_error = left(p_error, 500),
         not_before = p_now + least(interval '6 hours', make_interval(mins => power(2, greatest(attempts, 1))::int))
   where target_kind = p_kind and target_id = p_id
$$;

create or replace function public.defer_embed_jobs(p_minutes int, p_reason text, p_now timestamptz default now())
returns int language plpgsql security definer set search_path = public, pg_temp as $$
declare v_n int;
begin
  update public.embed_queue set not_before = p_now + make_interval(mins => p_minutes), last_error = left(p_reason, 500), locked_at = null
   where locked_at is null or locked_at = p_now;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- switching embedding models: re-embed everything that was embedded with another model
create or replace function public.requeue_embeddings_for_model(p_model text) returns int
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_n int := 0; v_m int;
begin
  insert into public.embed_queue (target_kind, target_id, dealer_id, reason)
  select 'kb_chunk', id, dealer_id, 'model_changed' from public.kb_chunks where embedding_model is distinct from p_model
  on conflict (target_kind, target_id) do update set not_before = now(), attempts = 0, reason = 'model_changed';
  get diagnostics v_n = row_count;
  insert into public.embed_queue (target_kind, target_id, dealer_id, reason)
  select 'vehicle_chunk', id, dealer_id, 'model_changed' from public.vehicle_listing_chunks where embedding_model is distinct from p_model
  on conflict (target_kind, target_id) do update set not_before = now(), attempts = 0, reason = 'model_changed';
  get diagnostics v_m = row_count;
  return v_n + v_m;
end $$;

-- OR-of-lexemes query: chat questions are long; AND semantics (websearch_to_tsquery) would match almost nothing
create or replace function public.kb_or_query(p_text text) returns tsquery language sql immutable as $$
  select case when cardinality(a) = 0 then null
              else to_tsquery('simple', array_to_string(array(select quote_literal(x) from unnest(a) x), ' | ')) end
    from (select tsvector_to_array(to_tsvector('english'::regconfig, coalesce(p_text, ''))) as a) s
$$;

-- Hybrid retrieval with Reciprocal Rank Fusion: score = sum over lists of 1 / (k + rank).
-- Dealer-scoped: service role passes any dealer; an authenticated caller must be a member of p_dealer_id.
-- p_query_embedding NULL => full-text only (mode = 'fts_only'), which is also the no-provider fallback.
create or replace function public.match_kb(
  p_dealer_id uuid, p_query text, p_query_embedding vector(1536) default null, p_embedding_model text default null,
  p_kinds text[] default null, p_match_count int default 6, p_include_vehicles boolean default true,
  p_min_similarity double precision default 0.25, p_rrf_k int default 60, p_now timestamptz default public.app_now())
returns table (source_kind text, chunk_id uuid, document_id uuid, vehicle_id uuid, title text, kind text, content text,
               source_uri text, document_version int, rrf_score double precision, fts_rank int, vec_rank int,
               similarity double precision, mode text)
language plpgsql stable security definer set search_path = public, extensions, pg_temp as $$
declare
  q tsquery := public.kb_or_query(p_query);
  v_mode text := case when p_query_embedding is null then 'fts_only' else 'hybrid' end;
  v_veh boolean := p_include_vehicles and (p_kinds is null or 'vehicle_description' = any (p_kinds));
  v_pool int := 40;
begin
  if auth.uid() is not null and not public.is_dealer_member(p_dealer_id) then
    raise exception 'not a member of dealer %', p_dealer_id using errcode = '42501';
  end if;
  begin perform set_config('hnsw.iterative_scan', 'relaxed_order', true); exception when others then null; end;
  p_match_count := least(greatest(coalesce(p_match_count, 6), 1), 20);
  return query
  with
  kb_fts as (
    select c.id, row_number() over (order by ts_rank_cd(c.fts, q) desc, c.id)::int as r
      from public.kb_chunks c join public.kb_documents d on d.id = c.document_id
     where q is not null and c.fts @@ q and c.dealer_id = p_dealer_id and d.status = 'active'
       and (d.valid_from is null or d.valid_from <= p_now) and (d.valid_until is null or d.valid_until > p_now)
       and (p_kinds is null or d.kind = any (p_kinds))
     order by ts_rank_cd(c.fts, q) desc, c.id limit v_pool),
  kb_vec as (
    select x.id, row_number() over (order by x.dist, x.id)::int as r, 1 - x.dist as sim
      from (select c.id, c.embedding <=> p_query_embedding as dist
              from public.kb_chunks c join public.kb_documents d on d.id = c.document_id
             where p_query_embedding is not null and c.embedding is not null and c.dealer_id = p_dealer_id
               and (p_embedding_model is null or c.embedding_model = p_embedding_model)
               and d.status = 'active'
               and (d.valid_from is null or d.valid_from <= p_now) and (d.valid_until is null or d.valid_until > p_now)
               and (p_kinds is null or d.kind = any (p_kinds))
             order by c.embedding <=> p_query_embedding limit v_pool) x),
  veh_fts as (
    select c.id, row_number() over (order by ts_rank_cd(c.fts, q) desc, c.id)::int as r
      from public.vehicle_listing_chunks c join public.vehicles v on v.id = c.vehicle_id
     where v_veh and q is not null and c.fts @@ q and c.dealer_id = p_dealer_id and v.status in ('available','in_transit')
     order by ts_rank_cd(c.fts, q) desc, c.id limit v_pool),
  veh_vec as (
    select x.id, row_number() over (order by x.dist, x.id)::int as r, 1 - x.dist as sim
      from (select c.id, c.embedding <=> p_query_embedding as dist
              from public.vehicle_listing_chunks c join public.vehicles v on v.id = c.vehicle_id
             where v_veh and p_query_embedding is not null and c.embedding is not null and c.dealer_id = p_dealer_id
               and (p_embedding_model is null or c.embedding_model = p_embedding_model)
               and v.status in ('available','in_transit')
             order by c.embedding <=> p_query_embedding limit v_pool) x),
  hits as (
    select 'kb'::text sk, id, r fr, null::int vr, null::double precision sim from kb_fts
    union all select 'kb', id, null, r, sim from kb_vec where sim >= p_min_similarity
    union all select 'vehicle', id, r, null, null from veh_fts
    union all select 'vehicle', id, null, r, sim from veh_vec where sim >= p_min_similarity),
  fused as (
    select sk, id, min(fr) fr, min(vr) vr, max(sim) sim,
           sum(1.0 / (p_rrf_k + coalesce(fr, vr)))::double precision as score
      from hits group by sk, id)
  select f.sk, f.id, k.document_id, vc.vehicle_id,
         coalesce(d.title, concat_ws(' ', v.year::text, v.make, v.model, v.trim)),
         coalesce(d.kind, 'vehicle_description'),
         coalesce(k.content, vc.content), d.source_uri, d.version,
         f.score, f.fr, f.vr, f.sim, v_mode
    from fused f
    left join public.kb_chunks k on f.sk = 'kb' and k.id = f.id
    left join public.kb_documents d on d.id = k.document_id
    left join public.vehicle_listing_chunks vc on f.sk = 'vehicle' and vc.id = f.id
    left join public.vehicles v on v.id = vc.vehicle_id
   order by f.score desc, f.sk, f.id
   limit p_match_count;
end $$;

-- citations: which retrieved passages a draft relied on (shown to the rep in review)
create table if not exists public.draft_citations (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  draft_id uuid not null references public.outbound_drafts(id) on delete cascade,
  kb_chunk_id uuid references public.kb_chunks(id) on delete set null,
  vehicle_chunk_id uuid references public.vehicle_listing_chunks(id) on delete set null,
  document_id uuid references public.kb_documents(id) on delete set null,
  document_version int,
  quote text check (quote is null or length(quote) <= 600),
  score double precision,
  run_id uuid references public.agent_runs(id) on delete set null,
  created_at timestamptz not null default now(),
  check (num_nonnulls(kb_chunk_id, vehicle_chunk_id) <= 1)
);
create index if not exists draft_citations_draft_idx on public.draft_citations (draft_id);

-- p_citations: [{"source_kind":"kb"|"vehicle","chunk_id":"...","score":0.03,"quote":"..."}]. Cross-dealer ids are dropped.
create or replace function public.record_draft_citations(p_draft_id uuid, p_citations jsonb, p_run_id uuid default null)
returns int language plpgsql security definer set search_path = public, pg_temp as $$
declare v_dealer uuid; v_n int;
begin
  select dealer_id into v_dealer from public.outbound_drafts where id = p_draft_id;
  if v_dealer is null then raise exception 'draft % not found', p_draft_id; end if;
  insert into public.draft_citations (dealer_id, draft_id, kb_chunk_id, vehicle_chunk_id, document_id, document_version, quote, score, run_id)
  select v_dealer, p_draft_id, k.id, vc.id, d.id, d.version, left(coalesce(c->>'quote', k.content, vc.content), 600), (c->>'score')::double precision, p_run_id
    from jsonb_array_elements(coalesce(p_citations, '[]'::jsonb)) c
    left join public.kb_chunks k on c->>'source_kind' = 'kb' and k.id = (c->>'chunk_id')::uuid and k.dealer_id = v_dealer
    left join public.kb_documents d on d.id = k.document_id
    left join public.vehicle_listing_chunks vc on c->>'source_kind' = 'vehicle' and vc.id = (c->>'chunk_id')::uuid and vc.dealer_id = v_dealer
   where k.id is not null or vc.id is not null;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- customer facts: one current value per (lead, key); provenance decides who may overwrite whom
create table if not exists public.customer_facts (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  lead_id uuid not null references public.leads(id) on delete cascade,
  fact_key text not null check (fact_key in (
    'budget_max_cents','monthly_budget_cents','down_payment_cents','purchase_timeframe','preferred_make','preferred_model',
    'preferred_trim','preferred_body_style','preferred_color','wants_financing','wants_lease','trade_in_year','trade_in_make',
    'trade_in_model','trade_in_mileage','trade_in_vin','preferred_contact_time','preferred_channel','household_drivers','primary_use')),
  value jsonb not null,
  source text not null check (source in ('ai_extracted','customer_form','rep_entered','dms')),
  confidence numeric(5,4) check (confidence is null or confidence between 0 and 1),
  evidence_quote text check (evidence_quote is null or length(evidence_quote) <= 300),
  message_id uuid references public.messages(id) on delete set null,
  run_id uuid references public.agent_runs(id) on delete set null,
  set_by uuid,
  superseded_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index if not exists customer_facts_current_uq on public.customer_facts (lead_id, fact_key) where superseded_at is null;

create or replace function public.fact_source_rank(p text) returns int language sql immutable as $$
  select case p when 'ai_extracted' then 1 when 'customer_form' then 2 when 'rep_entered' then 3 when 'dms' then 4 end
$$;

-- returns inserted | updated | unchanged | kept_existing (an AI guess never overwrites what a rep or the DMS recorded)
create or replace function public.upsert_customer_fact(p_dealer_id uuid, p_lead_id uuid, p_key text, p_value jsonb, p_source text,
  p_confidence numeric default null, p_quote text default null, p_message_id uuid default null, p_run_id uuid default null,
  p_set_by uuid default null, p_now timestamptz default now())
returns text language plpgsql security definer set search_path = public, pg_temp as $$
declare cur public.customer_facts;
begin
  if not exists (select 1 from public.leads where id = p_lead_id and dealer_id = p_dealer_id) then
    raise exception 'lead % not in dealer %', p_lead_id, p_dealer_id;
  end if;
  select * into cur from public.customer_facts where lead_id = p_lead_id and fact_key = p_key and superseded_at is null for update;
  if cur.id is not null then
    if cur.value = p_value then return 'unchanged'; end if;
    if public.fact_source_rank(p_source) < public.fact_source_rank(cur.source) then return 'kept_existing'; end if;
    update public.customer_facts set superseded_at = p_now where id = cur.id;
  end if;
  insert into public.customer_facts (dealer_id, lead_id, fact_key, value, source, confidence, evidence_quote, message_id, run_id, set_by, created_at)
  values (p_dealer_id, p_lead_id, p_key, p_value, p_source, p_confidence, left(p_quote, 300), p_message_id, p_run_id, p_set_by, p_now);
  return case when cur.id is null then 'inserted' else 'updated' end;
end $$;

-- =====================================================================================
-- PART H. FOLLOW-UP ENGINE (feature 6) + data the outbound sweeper needs
-- =====================================================================================
do $$ begin create type public.followup_trigger as enum ('stalled','promised','price_drop','test_drive_noshow','service_due','lease_end'); exception when duplicate_object then null; end $$;
do $$ begin create type public.followup_status as enum ('scheduled','claimed','drafted','sent','postponed','cancelled','exhausted'); exception when duplicate_object then null; end $$;

alter table public.dealer_settings add column if not exists followup_triggers public.followup_trigger[] not null
  default '{stalled,promised,price_drop,test_drive_noshow,service_due,lease_end}';
alter table public.dealer_settings add column if not exists followup_stalled_after_hours int not null default 48 check (followup_stalled_after_hours between 4 and 720);
alter table public.dealer_settings add column if not exists followup_stalled_max_per_30d int not null default 2 check (followup_stalled_max_per_30d between 0 and 10);
alter table public.dealer_settings add column if not exists followup_max_attempts int not null default 3 check (followup_max_attempts between 1 and 10);
alter table public.dealer_settings add column if not exists followup_postpone_days int not null default 7 check (followup_postpone_days between 1 and 30);
alter table public.dealer_settings add column if not exists followup_min_gap_hours int not null default 24 check (followup_min_gap_hours between 1 and 168);

-- inventory events (generic; vehicle_price_events stays for the briefing view)
create table if not exists public.vehicle_events (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  vehicle_id uuid not null references public.vehicles(id) on delete cascade,
  kind text not null check (kind in ('created','price_drop','price_increase','status_change','sold')),
  old_value jsonb not null default '{}'::jsonb,
  new_value jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now(),
  fanned_out_at timestamptz,
  fanout_count int
);
create index if not exists vehicle_events_fanout_idx on public.vehicle_events (occurred_at) where kind = 'price_drop' and fanned_out_at is null;
create index if not exists vehicle_events_vehicle_idx on public.vehicle_events (vehicle_id, occurred_at desc);

-- owned vehicles (service and lease reminders for customers who may have no open sales lead)
create table if not exists public.customer_vehicles (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  contact_id uuid not null references public.contacts(id) on delete cascade,
  lead_id uuid references public.leads(id) on delete set null,
  vin text, year int, make text, model text,
  last_service_on date, next_service_due_on date,
  created_at timestamptz not null default now()
);
create index if not exists customer_vehicles_service_idx on public.customer_vehicles (dealer_id, next_service_due_on);

create table if not exists public.followup_plans (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  lead_id uuid references public.leads(id) on delete cascade,
  contact_id uuid not null references public.contacts(id) on delete cascade,
  trigger_kind public.followup_trigger not null,
  source_ref uuid,                                           -- followups / vehicle_events / appointments / customer_vehicles id
  vehicle_id uuid references public.vehicles(id) on delete set null,
  purpose public.consent_purpose not null,                   -- price_drop/service/lease are marketing; the rest conversational
  channel public.channel_kind,                               -- null => sweeper picks (last inbound channel, else SMS)
  status public.followup_status not null default 'scheduled',
  due_at timestamptz not null,
  expires_at timestamptz not null,                           -- postponing past this => exhausted (never silently dropped)
  attempts int not null default 0,                           -- retryable failures (content vetoes, provider errors)
  max_attempts int not null default 3,
  postponed_count int not null default 0,                    -- quiet hours / caps (do not consume attempts)
  last_code text, stop_reason text,
  draft_id uuid references public.outbound_drafts(id) on delete set null,
  context jsonb not null default '{}'::jsonb,                -- frozen facts for drafting (ids, prices, dates; no message text)
  dedupe_key text not null,
  claimed_at timestamptz, finished_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists followup_plans_dedupe_uq on public.followup_plans (dealer_id, dedupe_key);
create index if not exists followup_plans_due_idx on public.followup_plans (due_at) where status in ('scheduled','postponed');
create index if not exists followup_plans_lead_idx on public.followup_plans (lead_id, created_at desc);
create index if not exists followup_plans_contact_active_idx on public.followup_plans (contact_id) where status in ('scheduled','postponed','claimed','drafted');

create or replace function public.followup_active_statuses() returns public.followup_status[] language sql immutable as $$
  select '{scheduled,postponed,claimed,drafted}'::public.followup_status[]
$$;

-- stop everything for a contact/lead (inbound reply, opt-out, won/lost). Returns rows cancelled.
create or replace function public.cancel_followup_plans(p_contact_id uuid, p_lead_id uuid, p_reason text,
  p_min_purpose public.consent_purpose default null, p_now timestamptz default now())
returns int language plpgsql security definer set search_path = public, pg_temp as $$
declare v_n int;
begin
  update public.followup_plans p
     set status = 'cancelled', stop_reason = p_reason, finished_at = p_now, updated_at = p_now
   where p.status = any (public.followup_active_statuses())
     and ((p_contact_id is not null and p.contact_id = p_contact_id) or (p_lead_id is not null and p.lead_id = p_lead_id))
     and (p_min_purpose is null or public.purpose_rank(p.purpose) >= public.purpose_rank(p_min_purpose));
  get diagnostics v_n = row_count;
  -- a drafted follow-up waiting for review is withdrawn too
  update public.outbound_drafts d set status = 'stale', updated_at = p_now
   where d.kind = 'followup' and d.status in ('awaiting_review','held','delayed')
     and d.id in (select draft_id from public.followup_plans where stop_reason = p_reason and finished_at = p_now and draft_id is not null);
  return v_n;
end $$;

create or replace function public.followups_stop_on_inbound() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.direction = 'inbound' and new.author_kind = 'contact' then
    perform public.cancel_followup_plans(new.contact_id, new.lead_id, 'customer_replied', null, new.created_at);
  end if;
  return new;
end $$;
drop trigger if exists messages_followups_stop_trg on public.messages;
create trigger messages_followups_stop_trg after insert on public.messages
  for each row execute function public.followups_stop_on_inbound();

create or replace function public.followups_stop_on_consent() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.action = 'revoke' then
    perform public.cancel_followup_plans(new.contact_id, null, case when new.purpose is null then 'opted_out' else 'consent_revoked' end,
                                         new.purpose, new.created_at);
  end if;
  return new;
end $$;
drop trigger if exists consent_events_followups_stop_trg on public.consent_events;
create trigger consent_events_followups_stop_trg after insert on public.consent_events
  for each row execute function public.followups_stop_on_consent();

create or replace function public.followups_stop_on_stage() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.stage in ('won','lost') and old.stage is distinct from new.stage then
    perform public.cancel_followup_plans(null, new.id, 'lead_closed_' || new.stage, null, now());
  end if;
  return new;
end $$;
drop trigger if exists leads_followups_stop_trg on public.leads;
create trigger leads_followups_stop_trg after update of stage on public.leads
  for each row execute function public.followups_stop_on_stage();

-- inventory change tracking: price drops feed both the briefing (vehicle_price_events) and the follow-up fan-out
create or replace function public.vehicles_track_events() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' then
    insert into public.vehicle_events (dealer_id, vehicle_id, kind, new_value) values (new.dealer_id, new.id, 'created', jsonb_build_object('status', new.status, 'price_cents', new.price_cents));
    return new;
  end if;
  if new.price_cents is distinct from old.price_cents and old.price_cents is not null and new.price_cents is not null then
    insert into public.vehicle_events (dealer_id, vehicle_id, kind, old_value, new_value)
    values (new.dealer_id, new.id, case when new.price_cents < old.price_cents then 'price_drop' else 'price_increase' end,
            jsonb_build_object('price_cents', old.price_cents), jsonb_build_object('price_cents', new.price_cents));
    if new.price_cents < old.price_cents then
      insert into public.vehicle_price_events (dealer_id, vehicle_id, old_price_cents, new_price_cents) values (new.dealer_id, new.id, old.price_cents, new.price_cents);
    end if;
  end if;
  if new.status is distinct from old.status then
    insert into public.vehicle_events (dealer_id, vehicle_id, kind, old_value, new_value)
    values (new.dealer_id, new.id, case when new.status = 'sold' then 'sold' else 'status_change' end,
            jsonb_build_object('status', old.status), jsonb_build_object('status', new.status));
    if new.status in ('sold','pending','hold') then          -- never advertise a car that is no longer for sale
      update public.followup_plans set status = 'cancelled', stop_reason = 'vehicle_' || new.status, finished_at = now(), updated_at = now()
       where vehicle_id = new.id and trigger_kind = 'price_drop' and status = any (public.followup_active_statuses());
    end if;
  end if;
  return new;
end $$;
drop trigger if exists vehicles_track_events_trg on public.vehicles;
create trigger vehicles_track_events_trg after insert or update of price_cents, status on public.vehicles
  for each row execute function public.vehicles_track_events();

-- has this contact a provable grant for the purpose on some channel (and no all-channel DNC)?
create or replace function public.contact_consented_channel(p_contact_id uuid, p_purpose public.consent_purpose)
returns public.channel_kind language sql stable security definer set search_path = public, pg_temp as $$
  select s.channel from public.contact_consent_state s
   where s.contact_id = p_contact_id and s.status = 'granted' and s.evidence_ok
     and public.purpose_rank(s.purpose) >= public.purpose_rank(p_purpose)
     and not exists (select 1 from public.contact_dnc x where x.contact_id = p_contact_id and x.cleared_at is null
                       and (x.channel is null or x.channel = s.channel))
   order by case s.channel when 'sms' then 1 when 'whatsapp' then 2 else 3 end
   limit 1
$$;

-- Plan generator: deterministic, idempotent (dedupe keys), run by pg_cron. Returns counts per trigger.
create or replace function public.generate_followup_plans(p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v jsonb := '{}'::jsonb; n int;
begin
  -- promised: the agent said "I'll check back Tuesday" (schedule_followup)
  with ins as (
    insert into public.followup_plans (dealer_id, lead_id, contact_id, trigger_kind, source_ref, purpose, due_at, expires_at, max_attempts, context, dedupe_key)
    select f.dealer_id, f.lead_id, l.contact_id, 'promised', f.id, 'conversational', f.due_at,
           f.due_at + make_interval(days => s.followup_postpone_days), s.followup_max_attempts,
           jsonb_build_object('reason', f.reason, 'promised_text', f.promised_text), 'promised:' || f.id
      from public.followups f join public.leads l on l.id = f.lead_id join public.dealer_settings s on s.dealer_id = f.dealer_id
     where f.kind = 'agent_promise' and f.status = 'scheduled' and f.due_at <= p_now + interval '5 minutes'
       and 'promised' = any (s.followup_triggers) and l.stage not in ('won','lost')
    on conflict (dealer_id, dedupe_key) do nothing returning source_ref)
  update public.followups set status = 'due' where id in (select source_ref from ins);
  get diagnostics n = row_count; v := v || jsonb_build_object('promised', n);

  -- stalled: we spoke last, they had engaged before, silence past the threshold; capped per 30 days
  insert into public.followup_plans (dealer_id, lead_id, contact_id, trigger_kind, purpose, due_at, expires_at, max_attempts, context, dedupe_key)
  select l.dealer_id, l.id, l.contact_id, 'stalled', 'conversational', p_now, p_now + make_interval(days => s.followup_postpone_days),
         s.followup_max_attempts, jsonb_build_object('stage', l.stage, 'silent_since', l.last_outbound_at),
         'stalled:' || l.id || ':' || extract(epoch from l.last_outbound_at)::bigint
    from public.leads l join public.dealer_settings s on s.dealer_id = l.dealer_id
   where 'stalled' = any (s.followup_triggers)
     and l.stage in ('contacted','qualifying','qualified','test_drive','negotiating')
     and l.last_inbound_at is not null and l.last_outbound_at > l.last_inbound_at
     and l.last_outbound_at < p_now - make_interval(hours => s.followup_stalled_after_hours)
     and l.last_outbound_at > p_now - interval '21 days'
     and not l.force_human
     and not exists (select 1 from public.followup_plans p where p.lead_id = l.id and p.status = any (public.followup_active_statuses()))
     and (select count(*) from public.followup_plans p where p.lead_id = l.id and p.trigger_kind = 'stalled'
            and p.status = 'sent' and p.finished_at > p_now - interval '30 days') < s.followup_stalled_max_per_30d
  on conflict (dealer_id, dedupe_key) do nothing;
  get diagnostics n = row_count; v := v || jsonb_build_object('stalled', n);

  -- test-drive no-show (one per appointment)
  insert into public.followup_plans (dealer_id, lead_id, contact_id, trigger_kind, source_ref, vehicle_id, purpose, due_at, expires_at, max_attempts, context, dedupe_key)
  select a.dealer_id, a.lead_id, l.contact_id, 'test_drive_noshow', a.id, a.vehicle_id, 'conversational',
         greatest(p_now, a.starts_at + interval '1 hour'), a.starts_at + interval '3 days', s.followup_max_attempts,
         jsonb_build_object('appointment_id', a.id, 'starts_at', a.starts_at), 'noshow:' || a.id
    from public.appointments a join public.leads l on l.id = a.lead_id join public.dealer_settings s on s.dealer_id = a.dealer_id
   where 'test_drive_noshow' = any (s.followup_triggers) and a.kind in ('test_drive','showroom')
     and (a.status = 'no_show' or (a.status in ('requested','confirmed') and a.starts_at < p_now - interval '45 minutes'))
     and a.starts_at > p_now - interval '36 hours' and l.stage not in ('won','lost')
  on conflict (dealer_id, dedupe_key) do nothing;
  get diagnostics n = row_count; v := v || jsonb_build_object('test_drive_noshow', n);

  -- price drop fan-out: only leads who viewed THAT vehicle in 30 days AND hold provable marketing consent; one per lead per 7 days
  with ev as (
    select e.* from public.vehicle_events e
      join public.vehicles vh on vh.id = e.vehicle_id and vh.status = 'available'
      join public.dealer_settings s on s.dealer_id = e.dealer_id and 'price_drop' = any (s.followup_triggers)
     where e.kind = 'price_drop' and e.fanned_out_at is null and e.occurred_at > p_now - interval '48 hours'
     for update of e skip locked),
  cand as (
    select distinct on (l.id, ev.vehicle_id) ev.id as event_id, ev.dealer_id, ev.vehicle_id, l.id as lead_id, l.contact_id,
           public.contact_consented_channel(l.contact_id, 'marketing') as chan, ev.old_value, ev.new_value
      from ev
      join public.lead_vehicle_views lv on lv.vehicle_id = ev.vehicle_id and lv.viewed_at > p_now - interval '30 days'
      join public.leads l on l.id = lv.lead_id and l.dealer_id = ev.dealer_id
     where l.stage not in ('won','lost') and not l.force_human
     order by l.id, ev.vehicle_id, ev.occurred_at desc),
  ins as (
    insert into public.followup_plans (dealer_id, lead_id, contact_id, trigger_kind, source_ref, vehicle_id, purpose, channel, due_at, expires_at, max_attempts, context, dedupe_key)
    select c.dealer_id, c.lead_id, c.contact_id, 'price_drop', c.event_id, c.vehicle_id, 'marketing', c.chan, p_now, p_now + interval '3 days',
           s.followup_max_attempts,
           jsonb_build_object('vehicle_id', c.vehicle_id, 'old_price_cents', (c.old_value->>'price_cents')::bigint, 'new_price_cents', (c.new_value->>'price_cents')::bigint),
           'price_drop:' || c.lead_id || ':' || c.vehicle_id || ':' || to_char(p_now, 'IYYY-IW')
      from cand c join public.dealer_settings s on s.dealer_id = c.dealer_id
     where c.chan is not null
       and not exists (select 1 from public.followup_plans p where p.lead_id = c.lead_id and p.trigger_kind = 'price_drop' and p.created_at > p_now - interval '7 days')
    on conflict (dealer_id, dedupe_key) do nothing returning source_ref),
  done as (
    update public.vehicle_events e set fanned_out_at = p_now, fanout_count = (select count(*) from ins where ins.source_ref = e.id)
     where e.id in (select id from ev) returning 1)
  select count(*) into n from ins;          -- the 'done' CTE runs too: data-modifying CTEs always execute
  v := v || jsonb_build_object('price_drop', n);

  -- service due within 14 days (dealer-local date), one per due date
  insert into public.followup_plans (dealer_id, lead_id, contact_id, trigger_kind, source_ref, purpose, due_at, expires_at, max_attempts, context, dedupe_key)
  select cv.dealer_id, cv.lead_id, cv.contact_id, 'service_due', cv.id, 'marketing', p_now, p_now + interval '10 days', s.followup_max_attempts,
         jsonb_build_object('customer_vehicle_id', cv.id, 'next_service_due_on', cv.next_service_due_on, 'year', cv.year, 'make', cv.make, 'model', cv.model),
         'service:' || cv.id || ':' || cv.next_service_due_on
    from public.customer_vehicles cv join public.dealers d on d.id = cv.dealer_id join public.dealer_settings s on s.dealer_id = cv.dealer_id
   where 'service_due' = any (s.followup_triggers) and cv.next_service_due_on is not null
     and cv.next_service_due_on between (p_now at time zone d.timezone)::date and (p_now at time zone d.timezone)::date + 14
  on conflict (dealer_id, dedupe_key) do nothing;
  get diagnostics n = row_count; v := v || jsonb_build_object('service_due', n);

  -- lease end: one touch at the nearest of the 90/60/30-day marks
  insert into public.followup_plans (dealer_id, lead_id, contact_id, trigger_kind, purpose, due_at, expires_at, max_attempts, context, dedupe_key)
  select l.dealer_id, l.id, l.contact_id, 'lease_end', 'marketing', p_now, p_now + interval '14 days', s.followup_max_attempts,
         jsonb_build_object('lease_end_on', l.lease_end_on, 'mark_days', x.mark), 'lease:' || l.id || ':' || l.lease_end_on || ':' || x.mark
    from public.leads l join public.dealers d on d.id = l.dealer_id join public.dealer_settings s on s.dealer_id = l.dealer_id
    cross join lateral (select l.lease_end_on - (p_now at time zone d.timezone)::date as days_left) dl
    cross join lateral (select case when dl.days_left <= 30 then 30 when dl.days_left <= 60 then 60 else 90 end as mark) x
   where 'lease_end' = any (s.followup_triggers) and l.lease_end_on is not null
     and dl.days_left between 0 and 90 and l.stage not in ('won','lost')
  on conflict (dealer_id, dedupe_key) do nothing;
  get diagnostics n = row_count; v := v || jsonb_build_object('lease_end', n);
  return v;
end $$;

-- Sweeper claim: expire, reclaim stale claims, then claim due plans (FOR UPDATE SKIP LOCKED => parallel-safe).
-- Leads a person owns are skipped (they stay scheduled until expiry); one follow-up per contact per min_gap_hours.
create or replace function public.claim_due_followups(p_limit int default 50, p_now timestamptz default now())
returns setof public.followup_plans language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.followup_plans set status = 'exhausted', stop_reason = 'expired', finished_at = p_now, updated_at = p_now
   where status in ('scheduled','postponed') and expires_at <= p_now;
  update public.followup_plans set status = 'scheduled', updated_at = p_now
   where status = 'claimed' and claimed_at < p_now - interval '15 minutes';
  return query
  update public.followup_plans p set status = 'claimed', claimed_at = p_now, updated_at = p_now
   where p.id in (
     select z.id from public.followup_plans z
      where z.id in (
        select y.id from (
          select fp.id, row_number() over (partition by fp.contact_id order by fp.due_at, fp.id) as rn   -- one per contact per sweep
            from public.followup_plans fp
            join public.dealer_settings s on s.dealer_id = fp.dealer_id
            left join public.leads l on l.id = fp.lead_id
           where fp.status in ('scheduled','postponed') and fp.due_at <= p_now
             and (l.id is null or (not l.force_human and (l.bot_silenced_until is null or l.bot_silenced_until <= p_now)))
             and not exists (select 1 from public.followup_plans x where x.contact_id = fp.contact_id and x.id <> fp.id
                               and ((x.status = 'sent' and x.finished_at > p_now - make_interval(hours => s.followup_min_gap_hours)) or x.status = 'claimed'))
        ) y where y.rn = 1)
        and z.status in ('scheduled','postponed')
      order by z.due_at
      for update skip locked
      limit greatest(1, least(p_limit, 500)))
  returning p.*;
end $$;

-- The single state machine for a claimed plan. outcome: sent | drafted | delayed | retry | stop
create or replace function public.record_followup_outcome(p_plan_id uuid, p_outcome text, p_code text default null,
  p_not_before timestamptz default null, p_draft_id uuid default null, p_now timestamptz default now())
returns public.followup_status language plpgsql security definer set search_path = public, pg_temp as $$
declare p public.followup_plans; v_next timestamptz;
begin
  select * into p from public.followup_plans where id = p_plan_id for update;
  if p.id is null then raise exception 'plan % not found', p_plan_id; end if;
  if p.status <> 'claimed' then raise exception 'plan % is %, not claimed', p_plan_id, p.status using errcode = 'P0001'; end if;

  if p_outcome = 'sent' then
    update public.followup_plans set status = 'sent', last_code = p_code, draft_id = coalesce(p_draft_id, draft_id), finished_at = p_now, updated_at = p_now where id = p.id;
    if p.trigger_kind = 'promised' then update public.followups set status = 'done' where id = p.source_ref; end if;
    return 'sent';
  elsif p_outcome = 'drafted' then                                   -- auto-send off: a rep approves it from the queue
    update public.followup_plans set status = 'drafted', last_code = p_code, draft_id = p_draft_id, finished_at = p_now, updated_at = p_now where id = p.id;
    if p.trigger_kind = 'promised' then update public.followups set status = 'done' where id = p.source_ref; end if;
    return 'drafted';
  elsif p_outcome = 'delayed' then                                   -- quiet hours / cap / throttle: postpone, never drop
    v_next := greatest(coalesce(p_not_before, p_now + interval '15 minutes'), p_now + interval '1 minute');
    if v_next > p.expires_at then
      update public.followup_plans set status = 'exhausted', stop_reason = 'postpone_window_passed', last_code = p_code, finished_at = p_now, updated_at = p_now where id = p.id;
      perform public.followup_to_inbox(p, 'Follow-up could not go out in time', p_code);
      return 'exhausted';
    end if;
    update public.followup_plans set status = 'postponed', due_at = v_next, postponed_count = postponed_count + 1, last_code = p_code, updated_at = p_now where id = p.id;
    return 'postponed';
  elsif p_outcome = 'retry' then                                     -- content veto / provider error: capped, with backoff
    if p.attempts + 1 >= p.max_attempts then
      update public.followup_plans set status = 'exhausted', attempts = attempts + 1, stop_reason = 'max_attempts', last_code = p_code, finished_at = p_now, updated_at = p_now where id = p.id;
      perform public.followup_to_inbox(p, 'Follow-up failed repeatedly', p_code);
      return 'exhausted';
    end if;
    v_next := p_now + make_interval(hours => power(2, p.attempts)::int);   -- 1h, 2h, 4h ...
    update public.followup_plans set status = 'postponed', attempts = attempts + 1, due_at = least(v_next, expires_at - interval '1 minute'),
           last_code = p_code, updated_at = p_now where id = p.id;
    return 'postponed';
  elsif p_outcome = 'stop' then                                      -- no consent, DNC, person owns the lead: not ours to send
    update public.followup_plans set status = 'cancelled', stop_reason = coalesce(p_code, 'stopped'), last_code = p_code, finished_at = p_now, updated_at = p_now where id = p.id;
    return 'cancelled';
  end if;
  raise exception 'unknown outcome %', p_outcome;
end $$;

create or replace function public.followup_to_inbox(p public.followup_plans, p_title text, p_code text) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into public.agent_inbox_items (dealer_id, lead_id, kind, priority, title, summary, payload)
  select p.dealer_id, p.lead_id, 'needs_review', 2, p_title,
         format('%s follow-up stopped (%s). Reach out personally if it still matters.', replace(p.trigger_kind::text, '_', ' '), coalesce(p_code, 'no code')),
         jsonb_build_object('plan_id', p.id, 'trigger', p.trigger_kind, 'code', p_code)
   where p.lead_id is not null
  on conflict (lead_id, kind) where status = 'open' and lead_id is not null do nothing
$$;

-- Route: preferred channel if usable, else the channel they last wrote on, else SMS, else email. Null => unreachable.
create or replace function public.pick_send_route(p_dealer_id uuid, p_contact_id uuid, p_preferred public.channel_kind default null)
returns table (channel public.channel_kind, number_id uuid) language sql stable security definer set search_path = public, pg_temp as $$
  with c as (select * from public.contacts where id = p_contact_id and dealer_id = p_dealer_id),
  last_in as (select m.channel from public.messages m where m.contact_id = p_contact_id and m.direction = 'inbound' order by m.created_at desc limit 1),
  opts as (
    select ch, ord from (values (p_preferred, 1), ((select channel from last_in), 2), ('sms'::public.channel_kind, 3), ('whatsapp'::public.channel_kind, 4), ('email'::public.channel_kind, 5)) v(ch, ord)
     where ch is not null)
  select o.ch, n.id
    from opts o cross join c
    join lateral (select id from public.channel_numbers n where n.dealer_id = p_dealer_id and n.channel = o.ch and n.status = 'active'
                   order by n.activated_at nulls last limit 1) n on true
   where ((o.ch in ('sms','whatsapp') and coalesce(c.phone_e164, '') <> '') or (o.ch = 'email' and coalesce(c.email, '') <> ''))
     and not exists (select 1 from public.contact_dnc x where x.contact_id = p_contact_id and x.cleared_at is null and (x.channel is null or x.channel = o.ch))
   order by o.ord limit 1
$$;

-- Everything the TS before-send chain needs for one lead/contact, in one round trip (also used by the agent runner
-- and the briefing). Never includes message bodies except the latest inbound (needed by the opt-out gate).
create or replace function public.get_gate_context(p_dealer_id uuid, p_contact_id uuid, p_lead_id uuid, p_channel public.channel_kind,
  p_now timestamptz default now())
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'dealer_name', d.name,
    'contact', jsonb_build_object('id', c.id, 'dnc_open', exists (select 1 from public.contact_dnc x where x.contact_id = c.id and x.cleared_at is null and (x.channel is null or x.channel = p_channel))),
    'lead', jsonb_build_object(
       'id', l.id, 'stage', l.stage, 'force_human', coalesce(l.force_human, false), 'bot_silenced_until', l.bot_silenced_until,
       'context_version', l.context_version,
       'ai_replies_since_inbound', (select count(*) from public.messages m where m.contact_id = c.id and m.direction = 'outbound' and m.author_kind = 'ai'
                                     and m.created_at > coalesce((select max(created_at) from public.messages i where i.contact_id = c.id and i.direction = 'inbound'), '-infinity'))),
    'latest_inbound', (select jsonb_build_object('id', m.id, 'body', m.body, 'at', m.created_at, 'channel', m.channel) from public.messages m
                        where m.contact_id = c.id and m.direction = 'inbound' order by m.created_at desc limit 1),
    'thread', jsonb_build_object(
       'prior_ai_messages', (select count(*) from public.messages m where m.contact_id = c.id and m.direction = 'outbound' and m.author_kind = 'ai'),
       'prior_outbound_on_channel', (select count(*) from public.messages m where m.contact_id = c.id and m.direction = 'outbound' and m.channel = p_channel)),
    'budget', (select jsonb_build_object('cap_cents', b.monthly_cap_cents, 'spent_cents', b.spent_cents, 'hard_stop', b.hard_stop) from public.ai_budgets b where b.dealer_id = p_dealer_id),
    'settings', jsonb_build_object(
       'ai_disclosure_text', s.ai_disclosure_text, 'stop_footer_text', s.stop_footer_text, 'rep_hold_minutes', s.rep_hold_minutes,
       'followup_hold_minutes', s.followup_hold_minutes, 'auto_send_enabled', s.auto_send_enabled, 'auto_send_kinds', to_jsonb(s.auto_send_kinds),
       'ai_max_unanswered_replies', s.ai_max_unanswered_replies, 'followup_handoff_hours', s.followup_handoff_hours))
    from public.dealers d
    join public.dealer_settings s on s.dealer_id = d.id
    join public.contacts c on c.id = p_contact_id and c.dealer_id = d.id
    left join public.leads l on l.id = p_lead_id and l.dealer_id = d.id
   where d.id = p_dealer_id
$$;

-- Sweeper bookkeeping after a provider send (or failure): message row + reservation confirm/release + draft status.
create or replace function public.finalize_draft_send(p_draft_id uuid, p_ok boolean, p_provider_message_id text default null,
  p_error text default null, p_body text default null, p_now timestamptz default now())
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare d public.outbound_drafts; v_msg uuid;
begin
  select * into d from public.outbound_drafts where id = p_draft_id for update;
  if d.id is null then raise exception 'draft % not found', p_draft_id; end if;
  if d.status <> 'sending' then raise exception 'draft % is %, not sending', p_draft_id, d.status; end if;
  if p_ok then
    insert into public.messages (dealer_id, lead_id, contact_id, number_id, channel, direction, author_kind, body, provider_message_id, status, created_at)
    values (d.dealer_id, d.lead_id, d.contact_id, d.number_id, d.channel, 'outbound', d.actor, coalesce(p_body, d.body_edited, d.body_ai), p_provider_message_id, 'sent', p_now)
    returning id into v_msg;
    if d.reservation_id is not null then perform public.confirm_send(d.reservation_id, v_msg, p_now); end if;
    update public.outbound_drafts set status = 'sent', message_id = v_msg, updated_at = p_now where id = d.id;
    update public.followup_plans set status = 'sent', finished_at = p_now, updated_at = p_now where draft_id = d.id and status = 'drafted';
  else
    if d.reservation_id is not null then perform public.release_send(d.reservation_id, left(p_error, 200)); end if;
    update public.outbound_drafts set status = 'failed', veto_code = left(coalesce(p_error, 'provider_error'), 120), updated_at = p_now where id = d.id;
  end if;
  return v_msg;
end $$;

-- =====================================================================================
-- PART I. REPLY CLASSIFICATION + AUTOMATIC PIPELINE MOVES (feature 5)
-- =====================================================================================
do $$ begin create type public.reply_category as enum (
  'test_drive_requested','ready_to_buy','financing_prequal','trade_in_inquiry','price_shopper','just_looking',
  'reschedule','not_now','bought_elsewhere','do_not_contact','other'); exception when duplicate_object then null; end $$;
do $$ begin create type public.classification_status as enum ('proposed','auto_applied','accepted','rejected','overridden','stale','failed'); exception when duplicate_object then null; end $$;

alter table public.dealer_settings add column if not exists classify_auto_apply boolean not null default true;
alter table public.dealer_settings add column if not exists classify_min_confidence numeric(5,4) not null default 0.85 check (classify_min_confidence between 0.5 and 1);

alter table public.lead_activities add column if not exists classification_id uuid;
alter table public.lead_activities add column if not exists message_id uuid;
alter table public.lead_activities add column if not exists undone_at timestamptz;
alter table public.lead_activities add column if not exists undone_by uuid;
alter table public.lead_activities add column if not exists undo_of uuid references public.lead_activities(id) on delete set null;

create table if not exists public.classifications (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  lead_id uuid not null references public.leads(id) on delete cascade,
  message_id uuid not null references public.messages(id) on delete cascade,
  category public.reply_category,                            -- null only when status = failed
  confidence numeric(5,4) check (confidence is null or confidence between 0 and 1),
  evidence_quote text check (evidence_quote is null or length(evidence_quote) <= 300),
  rationale text check (rationale is null or length(rationale) <= 500),
  source text not null default 'llm' check (source in ('llm','rule')),
  model text, prompt_version text,
  from_stage text, proposed_stage text,
  status public.classification_status not null default 'proposed',
  context_version_at int not null,
  activity_id uuid references public.lead_activities(id) on delete set null,
  decided_by uuid, decided_at timestamptz, override_stage text,
  error text,
  created_at timestamptz not null default now(),
  check (status = 'failed' or category is not null)
);
create unique index if not exists classifications_message_live_uq on public.classifications (message_id) where status <> 'failed';
create index if not exists classifications_review_idx on public.classifications (dealer_id, created_at desc) where status = 'proposed';
create index if not exists classifications_lead_idx on public.classifications (lead_id, created_at desc);
do $$ begin
  alter table public.lead_activities add constraint lead_activities_classification_fk foreign key (classification_id) references public.classifications(id) on delete set null;
exception when duplicate_object then null; end $$;

-- category -> the stage it implies (null = no pipeline meaning)
create or replace function public.category_target_stage(p public.reply_category) returns text language sql immutable as $$
  select case p when 'test_drive_requested' then 'test_drive' when 'ready_to_buy' then 'negotiating'
                when 'financing_prequal' then 'qualified' when 'trade_in_inquiry' then 'qualifying'
                when 'price_shopper' then 'qualifying' when 'just_looking' then 'contacted'
                when 'bought_elsewhere' then 'lost' else null end
$$;

-- Deterministic apply policy (the model only labels; this function decides):
--   stale context -> stale | do_not_contact -> opt-out NOW (all channels) | closed lead or lost/bought_elsewhere -> review
--   no forward move -> auto_applied (timeline note only) | below dealer threshold or auto-apply off -> review | else move.
create or replace function public.apply_classification(p_classification_id uuid, p_now timestamptz default now())
returns public.classification_status language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.classifications; l public.leads; s public.dealer_settings; v_to text; v_act uuid; v_status public.classification_status;
begin
  select * into c from public.classifications where id = p_classification_id for update;
  if c.id is null then raise exception 'classification % not found', p_classification_id; end if;
  if c.status <> 'proposed' or c.decided_at is not null then return c.status; end if;
  select * into l from public.leads where id = c.lead_id for update;
  select * into s from public.dealer_settings where dealer_id = c.dealer_id;

  if l.context_version <> c.context_version_at then
    update public.classifications set status = 'stale', decided_at = p_now where id = c.id;
    return 'stale';
  end if;

  if c.category = 'do_not_contact' then
    perform public.record_opt_out(c.dealer_id, l.contact_id, null, 'inbound_message',
      jsonb_build_object('classification_id', c.id, 'message_id', c.message_id, 'quote', c.evidence_quote), 'classified as do_not_contact');
    insert into public.lead_activities (dealer_id, lead_id, actor_kind, kind, confidence, reason, evidence, classification_id, message_id, created_at)
    values (c.dealer_id, l.id, 'system', 'opted_out', c.confidence, 'Customer asked not to be contacted', jsonb_build_object('quote', c.evidence_quote), c.id, c.message_id, p_now)
    returning id into v_act;
    insert into public.agent_inbox_items (dealer_id, lead_id, kind, priority, title, summary, payload)
    values (c.dealer_id, l.id, 'ambiguous_stop', 1, 'Opted out (classified)', 'All automated contact stopped. Only the customer can opt back in.', jsonb_build_object('classification_id', c.id))
    on conflict (lead_id, kind) where status = 'open' and lead_id is not null do nothing;
    update public.classifications set status = 'auto_applied', from_stage = l.stage, activity_id = v_act, decided_at = p_now where id = c.id;
    return 'auto_applied';
  end if;

  v_to := public.category_target_stage(c.category);
  if v_to is null or (v_to <> 'lost' and l.stage not in ('won','lost') and public.lead_stage_rank(v_to) <= public.lead_stage_rank(l.stage)) then
    v_status := 'auto_applied';                               -- forward-only: nothing to move, keep a timeline note
    insert into public.lead_activities (dealer_id, lead_id, actor_kind, kind, from_stage, to_stage, confidence, reason, evidence, classification_id, message_id, created_at)
    values (c.dealer_id, l.id, 'ai', 'classified', l.stage, null, c.confidence, format('Reply classified as %s', c.category),
            jsonb_build_object('quote', c.evidence_quote, 'category', c.category), c.id, c.message_id, p_now)
    returning id into v_act;
  elsif v_to = 'lost' or l.stage in ('won','lost') or not s.classify_auto_apply or c.confidence < s.classify_min_confidence then
    v_status := 'proposed';
    insert into public.lead_activities (dealer_id, lead_id, actor_kind, kind, from_stage, to_stage, confidence, reason, evidence, classification_id, message_id, created_at)
    values (c.dealer_id, l.id, 'ai', 'stage_change_proposed', l.stage, v_to, c.confidence, format('Reply classified as %s', c.category),
            jsonb_build_object('quote', c.evidence_quote, 'category', c.category), c.id, c.message_id, p_now)
    returning id into v_act;
    insert into public.agent_inbox_items (dealer_id, lead_id, kind, priority, title, summary, payload)
    values (c.dealer_id, l.id, 'classification_review', 2, format('Confirm stage: %s -> %s', l.stage, v_to),
            format('"%s" (%s, %s)', left(coalesce(c.evidence_quote, ''), 140), c.category, c.confidence),
            jsonb_build_object('classification_id', c.id, 'from', l.stage, 'to', v_to))
    on conflict (lead_id, kind) where status = 'open' and lead_id is not null
    do update set payload = excluded.payload, title = excluded.title, summary = excluded.summary;
  else
    v_status := 'auto_applied';
    update public.leads set stage = v_to, updated_at = p_now where id = l.id;
    insert into public.lead_activities (dealer_id, lead_id, actor_kind, kind, from_stage, to_stage, confidence, reason, evidence, classification_id, message_id, created_at)
    values (c.dealer_id, l.id, 'ai', 'stage_changed', l.stage, v_to, c.confidence, format('Moved to %s because the customer said "%s"', v_to, left(coalesce(c.evidence_quote, ''), 140)),
            jsonb_build_object('quote', c.evidence_quote, 'category', c.category), c.id, c.message_id, p_now)
    returning id into v_act;
  end if;
  update public.classifications set status = v_status, from_stage = l.stage, proposed_stage = v_to, activity_id = v_act,
         decided_at = case when v_status = 'proposed' then null else p_now end
   where id = c.id;
  return v_status;
end $$;

-- record + apply in one call (the inbound pipeline's only entry point)
create or replace function public.record_classification(p_message_id uuid, p_category public.reply_category, p_confidence numeric,
  p_quote text, p_rationale text, p_source text default 'llm', p_model text default null, p_prompt_version text default null,
  p_context_version int default null, p_now timestamptz default now())
returns table (classification_id uuid, status public.classification_status)
language plpgsql security definer set search_path = public, pg_temp as $$
declare m public.messages; v_id uuid; v_cv int;
begin
  select * into m from public.messages where id = p_message_id;
  if m.id is null or m.lead_id is null then raise exception 'message % not found or has no lead', p_message_id; end if;
  if m.direction <> 'inbound' then raise exception 'only inbound messages are classified'; end if;
  select coalesce(p_context_version, context_version) into v_cv from public.leads where id = m.lead_id;
  insert into public.classifications (dealer_id, lead_id, message_id, category, confidence, evidence_quote, rationale, source, model, prompt_version, context_version_at, created_at)
  values (m.dealer_id, m.lead_id, m.id, p_category, least(greatest(p_confidence, 0), 1), left(p_quote, 300), left(p_rationale, 500), p_source, p_model, p_prompt_version, v_cv, p_now)
  returning id into v_id;
  classification_id := v_id;
  status := public.apply_classification(v_id, p_now);
  return next;
end $$;

create or replace function public.record_classification_failure(p_message_id uuid, p_error text, p_model text default null, p_now timestamptz default now())
returns uuid language sql security definer set search_path = public, pg_temp as $$
  insert into public.classifications (dealer_id, lead_id, message_id, status, error, model, context_version_at, created_at)
  select m.dealer_id, m.lead_id, m.id, 'failed', left(p_error, 500), p_model, l.context_version, p_now
    from public.messages m join public.leads l on l.id = m.lead_id where m.id = p_message_id
  returning id
$$;

-- actor resolution for staff RPCs: an authenticated caller acts as themselves; the service role passes p_actor
create or replace function public.require_staff(p_dealer_id uuid, p_actor uuid, p_roles text[] default array['owner','admin','manager','sales','bdc'])
returns uuid language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v uuid := coalesce(auth.uid(), p_actor);
begin
  if v is null then raise exception 'actor required' using errcode = '42501'; end if;
  if not exists (select 1 from public.dealer_members m where m.user_id = v and m.dealer_id = p_dealer_id and m.role::text = any (p_roles)) then
    raise exception 'forbidden: user % lacks role % at dealer %', v, p_roles, p_dealer_id using errcode = '42501';
  end if;
  return v;
end $$;

create or replace function public.set_lead_stage_human(c public.classifications, p_stage text, p_actor uuid, p_kind text, p_now timestamptz)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare v_from text; v_act uuid;
begin
  if public.lead_stage_rank(p_stage) is null then raise exception 'unknown stage %', p_stage; end if;
  select stage into v_from from public.leads where id = c.lead_id for update;
  if v_from is distinct from p_stage then
    update public.leads set stage = p_stage, updated_at = p_now where id = c.lead_id;
  end if;
  insert into public.lead_activities (dealer_id, lead_id, actor_kind, actor_id, kind, from_stage, to_stage, confidence, reason, evidence, classification_id, message_id, created_at)
  values (c.dealer_id, c.lead_id, 'human', p_actor, 'stage_changed', v_from, p_stage, c.confidence, p_kind, jsonb_build_object('category', c.category, 'quote', c.evidence_quote), c.id, c.message_id, p_now)
  returning id into v_act;
  update public.agent_inbox_items set status = 'resolved', resolved_at = p_now, resolved_by = p_actor
   where lead_id = c.lead_id and kind = 'classification_review' and status = 'open';
  return v_act;
end $$;

create or replace function public.accept_classification(p_classification_id uuid, p_actor uuid default null, p_now timestamptz default now())
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.classifications; v_actor uuid; v_act uuid;
begin
  select * into c from public.classifications where id = p_classification_id for update;
  if c.id is null then raise exception 'classification not found'; end if;
  v_actor := public.require_staff(c.dealer_id, p_actor);
  if c.status <> 'proposed' then raise exception 'classification is %, not proposed', c.status; end if;
  if c.proposed_stage is null then raise exception 'nothing to apply'; end if;
  v_act := public.set_lead_stage_human(c, c.proposed_stage, v_actor, 'accepted AI proposal', p_now);
  update public.classifications set status = 'accepted', decided_by = v_actor, decided_at = p_now, activity_id = v_act where id = c.id;
  return v_act;
end $$;

create or replace function public.reject_classification(p_classification_id uuid, p_actor uuid default null, p_now timestamptz default now())
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.classifications; v_actor uuid;
begin
  select * into c from public.classifications where id = p_classification_id for update;
  if c.id is null then raise exception 'classification not found'; end if;
  v_actor := public.require_staff(c.dealer_id, p_actor);
  if c.status = 'auto_applied' and exists (select 1 from public.lead_activities a where a.id = c.activity_id and a.kind = 'stage_changed') then
    perform public.undo_stage_change(c.activity_id, v_actor, 'rejected AI move', p_now);   -- also marks it rejected
    return;
  end if;
  if c.status <> 'proposed' then raise exception 'classification is %, cannot reject', c.status; end if;
  update public.classifications set status = 'rejected', decided_by = v_actor, decided_at = p_now where id = c.id;
  update public.agent_inbox_items set status = 'dismissed', resolved_at = p_now, resolved_by = v_actor
   where lead_id = c.lead_id and kind = 'classification_review' and status = 'open';
end $$;

-- rep picks a different stage than the model (from a proposal, or after an auto move)
create or replace function public.override_classification(p_classification_id uuid, p_stage text, p_actor uuid default null, p_now timestamptz default now())
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.classifications; v_actor uuid; v_act uuid;
begin
  select * into c from public.classifications where id = p_classification_id for update;
  if c.id is null then raise exception 'classification not found'; end if;
  v_actor := public.require_staff(c.dealer_id, p_actor);
  if c.status not in ('proposed','auto_applied') then raise exception 'classification is %, cannot override', c.status; end if;
  if c.status = 'auto_applied' and exists (select 1 from public.lead_activities a where a.id = c.activity_id and a.kind = 'stage_changed' and a.undone_at is null) then
    perform public.undo_stage_change(c.activity_id, v_actor, 'override', p_now);
  end if;
  v_act := public.set_lead_stage_human(c, p_stage, v_actor, 'override of AI classification', p_now);
  update public.classifications set status = 'overridden', override_stage = p_stage, decided_by = v_actor, decided_at = p_now, activity_id = v_act where id = c.id;
  return v_act;
end $$;

-- One-click undo of any stage change (AI or human). Only the latest change can be undone (stage must still match).
create or replace function public.undo_stage_change(p_activity_id uuid, p_actor uuid default null, p_reason text default null, p_now timestamptz default now())
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare a public.lead_activities; v_actor uuid; v_stage text; v_new uuid;
begin
  select * into a from public.lead_activities where id = p_activity_id for update;
  if a.id is null then raise exception 'activity not found'; end if;
  v_actor := public.require_staff(a.dealer_id, p_actor);
  if a.kind <> 'stage_changed' then raise exception 'only stage changes can be undone'; end if;
  if a.undone_at is not null then raise exception 'already undone' using errcode = 'P0001'; end if;
  select stage into v_stage from public.leads where id = a.lead_id for update;
  if v_stage is distinct from a.to_stage then
    raise exception 'lead moved since (now %); undo the newer change first', v_stage using errcode = 'P0001';
  end if;
  update public.leads set stage = a.from_stage, updated_at = p_now where id = a.lead_id;
  update public.lead_activities set undone_at = p_now, undone_by = v_actor where id = a.id;
  insert into public.lead_activities (dealer_id, lead_id, actor_kind, actor_id, kind, from_stage, to_stage, reason, evidence, classification_id, undo_of, created_at)
  values (a.dealer_id, a.lead_id, 'human', v_actor, 'stage_change_undone', a.to_stage, a.from_stage, coalesce(p_reason, 'undo'), '{}'::jsonb, a.classification_id, a.id, p_now)
  returning id into v_new;
  if a.classification_id is not null then
    update public.classifications set status = 'rejected', decided_by = v_actor, decided_at = p_now
     where id = a.classification_id and status in ('auto_applied','accepted');
  end if;
  return v_new;
end $$;

-- a newer customer message makes open proposals stale (the rep should judge the latest context)
create or replace function public.classifications_stale_on_inbound() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.direction = 'inbound' and new.lead_id is not null then
    update public.classifications set status = 'stale', decided_at = new.created_at
     where lead_id = new.lead_id and status = 'proposed' and message_id <> new.id;
  end if;
  return new;
end $$;
drop trigger if exists messages_classifications_stale_trg on public.messages;
create trigger messages_classifications_stale_trg after insert on public.messages
  for each row execute function public.classifications_stale_on_inbound();

-- timeline: activities + messages (security_invoker => caller's RLS)
create or replace view public.v_lead_timeline with (security_invoker = true) as
select a.dealer_id, a.lead_id, a.created_at as at, 'activity'::text as item_type, a.kind, a.actor_kind,
       a.from_stage, a.to_stage, a.confidence, a.reason as summary, a.id as activity_id, a.classification_id,
       (a.kind = 'stage_changed' and a.undone_at is null) as undoable
  from public.lead_activities a
union all
select m.dealer_id, m.lead_id, m.created_at, 'message', m.direction, m.author_kind, null, null, null, left(m.body, 280), null, null, false
  from public.messages m where m.lead_id is not null;

-- =====================================================================================
-- PART J. CRM BY TEXT + MCP (feature 7)
-- =====================================================================================
create table if not exists public.staff_identities (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  user_id uuid not null,
  channel public.channel_kind not null,
  address text not null,                                     -- E.164 or lower-cased email
  status text not null default 'pending' check (status in ('pending','active','revoked')),
  verified_at timestamptz,
  created_by uuid,
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  check (status <> 'active' or verified_at is not null)
);
create unique index if not exists staff_identities_live_uq on public.staff_identities (dealer_id, channel, address) where status <> 'revoked';

create table if not exists public.mcp_api_keys (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  acting_user_id uuid not null,                              -- whose visibility a 'sales' key gets
  name text not null,
  key_prefix text not null,                                  -- shown in the UI ("sos_ab12cd34...")
  key_hash text not null unique,                             -- sha256 hex; the plaintext is shown once
  role text not null check (role in ('viewer','sales','manager','admin')),
  scopes text[] not null,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  last_used_at timestamptz,
  expires_at timestamptz,
  revoked_at timestamptz
);
create index if not exists mcp_api_keys_dealer_idx on public.mcp_api_keys (dealer_id);

create table if not exists public.mcp_audit_log (
  id bigint generated always as identity primary key,
  dealer_id uuid not null references public.dealers(id) on delete cascade,
  actor_kind text not null check (actor_kind in ('api_key','staff_sms','staff_whatsapp','staff_email')),
  api_key_id uuid references public.mcp_api_keys(id) on delete set null,
  staff_identity_id uuid references public.staff_identities(id) on delete set null,
  user_id uuid,
  tool text not null,
  args jsonb not null default '{}'::jsonb,                   -- redacted by the caller (no message bodies)
  result_code text not null,
  lead_id uuid, draft_id uuid,
  created_at timestamptz not null default now()
);
create index if not exists mcp_audit_dealer_idx on public.mcp_audit_log (dealer_id, created_at desc);
create or replace function public.mcp_audit_append_only() returns trigger language plpgsql as $$
begin raise exception 'mcp_audit_log is append-only'; end $$;
drop trigger if exists mcp_audit_no_update on public.mcp_audit_log;
create trigger mcp_audit_no_update before update or delete on public.mcp_audit_log for each row execute function public.mcp_audit_append_only();

create or replace function public.mcp_role_scopes(p_role text) returns text[] language sql immutable as $$
  select case p_role
    when 'viewer'  then array['leads:read','inventory:read']
    when 'sales'   then array['leads:read','inventory:read','leads:write','tasks:write','drafts:write']
    when 'manager' then array['leads:read','inventory:read','leads:write','tasks:write','drafts:write','leads:read_all']
    when 'admin'   then array['leads:read','inventory:read','leads:write','tasks:write','drafts:write','leads:read_all','keys:manage']
    else array[]::text[] end
$$;
-- dealer_members.role -> MCP role
create or replace function public.mcp_role_for_member(p_role text) returns text language sql immutable as $$
  select case when p_role in ('owner','admin') then 'admin' when p_role = 'manager' then 'manager'
              when p_role in ('sales','bdc') then 'sales' when p_role = 'viewer' then 'viewer' else null end
$$;

-- owner/admin creates a key; returns the plaintext ONCE
create or replace function public.create_mcp_api_key(p_dealer_id uuid, p_name text, p_role text, p_acting_user_id uuid default null,
  p_expires_at timestamptz default null, p_actor uuid default null)
returns table (key_id uuid, api_key text, key_prefix text) language plpgsql security definer set search_path = public, pg_temp as $$
declare v_actor uuid; v_user uuid; v_key text; v_member_role text;
begin
  v_actor := public.require_staff(p_dealer_id, p_actor, array['owner','admin']);
  v_user := coalesce(p_acting_user_id, v_actor);
  select m.role::text into v_member_role from public.dealer_members m where m.user_id = v_user and m.dealer_id = p_dealer_id;
  if v_member_role is null then raise exception 'acting user is not a member of this dealer'; end if;
  if public.mcp_role_scopes(p_role) = array[]::text[] then raise exception 'unknown role %', p_role; end if;
  if array_position(array['viewer','sales','manager','admin'], p_role) > array_position(array['viewer','sales','manager','admin'], public.mcp_role_for_member(v_member_role)) then
    raise exception 'key role % exceeds the acting user''s role %', p_role, v_member_role;
  end if;
  v_key := 'sos_' || replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into public.mcp_api_keys (dealer_id, acting_user_id, name, key_prefix, key_hash, role, scopes, created_by, expires_at)
  values (p_dealer_id, v_user, p_name, left(v_key, 12), encode(sha256(convert_to(v_key, 'UTF8')), 'hex'), p_role, public.mcp_role_scopes(p_role), v_actor, p_expires_at)
  returning id into key_id;
  api_key := v_key; key_prefix := left(v_key, 12);
  return next;
end $$;

create or replace function public.revoke_mcp_api_key(p_key_id uuid, p_actor uuid default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_dealer uuid;
begin
  select dealer_id into v_dealer from public.mcp_api_keys where id = p_key_id;
  if v_dealer is null then raise exception 'key not found'; end if;
  perform public.require_staff(v_dealer, p_actor, array['owner','admin']);
  update public.mcp_api_keys set revoked_at = coalesce(revoked_at, now()) where id = p_key_id;
end $$;

-- service role only: resolves a bearer key; the acting user's current membership caps the key (demotion takes effect at once)
create or replace function public.verify_mcp_api_key(p_key text, p_now timestamptz default now())
returns table (key_id uuid, dealer_id uuid, acting_user_id uuid, role text, scopes text[])
language plpgsql security definer set search_path = public, pg_temp as $$
declare k public.mcp_api_keys; v_member_role text; v_role text;
begin
  select * into k from public.mcp_api_keys where key_hash = encode(sha256(convert_to(coalesce(p_key, ''), 'UTF8')), 'hex');
  if k.id is null or k.revoked_at is not null or (k.expires_at is not null and k.expires_at <= p_now) then return; end if;
  select m.role::text into v_member_role from public.dealer_members m where m.user_id = k.acting_user_id and m.dealer_id = k.dealer_id;
  if v_member_role is null then return; end if;
  v_role := (select r from unnest(array['viewer','sales','manager','admin']) with ordinality u(r, o)
              where r in (k.role, public.mcp_role_for_member(v_member_role)) order by o limit 1);
  update public.mcp_api_keys set last_used_at = p_now where id = k.id;
  key_id := k.id; dealer_id := k.dealer_id; acting_user_id := k.acting_user_id; role := v_role; scopes := public.mcp_role_scopes(v_role);
  return next;
end $$;

-- staff texting the store number: active + verified identity of a current member. Text access never gets admin scopes.
create or replace function public.resolve_staff_sender(p_dealer_id uuid, p_channel public.channel_kind, p_address text)
returns table (staff_identity_id uuid, user_id uuid, role text, scopes text[])
language sql stable security definer set search_path = public, pg_temp as $$
  select si.id, si.user_id, r.role, public.mcp_role_scopes(r.role)
    from public.staff_identities si
    join public.dealer_members m on m.user_id = si.user_id and m.dealer_id = si.dealer_id
    cross join lateral (select case when public.mcp_role_for_member(m.role::text) = 'admin' then 'manager' else public.mcp_role_for_member(m.role::text) end as role) r
   where si.dealer_id = p_dealer_id and si.channel = p_channel and si.status = 'active' and si.verified_at is not null
     and si.address = case when p_channel = 'email' then lower(btrim(p_address)) else btrim(p_address) end
     and r.role is not null
$$;

create or replace function public.mcp_audit(p_dealer_id uuid, p_actor_kind text, p_api_key_id uuid, p_staff_identity_id uuid, p_user_id uuid,
  p_tool text, p_args jsonb, p_result_code text, p_lead_id uuid default null, p_draft_id uuid default null)
returns bigint language sql security definer set search_path = public, pg_temp as $$
  insert into public.mcp_audit_log (dealer_id, actor_kind, api_key_id, staff_identity_id, user_id, tool, args, result_code, lead_id, draft_id)
  values (p_dealer_id, p_actor_kind, p_api_key_id, p_staff_identity_id, p_user_id, p_tool, coalesce(p_args, '{}'::jsonb), p_result_code, p_lead_id, p_draft_id)
  returning id
$$;

create or replace function public.mcp_require(p_role text, p_scope text) returns void language plpgsql immutable as $$
begin
  if not (p_scope = any (public.mcp_role_scopes(p_role))) then
    raise exception 'forbidden: role % lacks scope %', p_role, p_scope using errcode = '42501';
  end if;
end $$;

create or replace function public.mcp_visible_lead(p_dealer_id uuid, p_user_id uuid, p_role text, p_lead_id uuid) returns public.leads
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare l public.leads;
begin
  select * into l from public.leads where id = p_lead_id and dealer_id = p_dealer_id;
  if l.id is null then raise exception 'not_found: lead' using errcode = 'P0002'; end if;
  if not ('leads:read_all' = any (public.mcp_role_scopes(p_role))) and l.assigned_to is not null and l.assigned_to <> p_user_id then
    raise exception 'not_found: lead' using errcode = 'P0002';          -- same answer as missing: no existence oracle
  end if;
  return l;
end $$;

create or replace function public.mcp_list_attention(p_dealer_id uuid, p_user_id uuid, p_role text, p_limit int default 7, p_now timestamptz default public.app_now())
returns table (lead_id uuid, name text, stage text, kind public.briefing_item_kind, reason text, score numeric)
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_all boolean;
begin
  perform public.mcp_require(p_role, 'leads:read');
  v_all := 'leads:read_all' = any (public.mcp_role_scopes(p_role));
  perform set_config('salesos.now', p_now::text, true);
  return query
  select x.lead_id, x.name, x.stage, x.kind, x.reason, x.score from (
    select distinct on (c.lead_id) c.lead_id, concat_ws(' ', ct.first_name, left(ct.last_name, 1)) as name, l.stage, c.kind,
           public.briefing_reason_text(c.kind, c.evidence, c.event_at, p_now) as reason, s.score
      from public.briefing_candidates c
      join public.leads l on l.id = c.lead_id
      join public.contacts ct on ct.id = l.contact_id
      cross join lateral public.briefing_kind_cfg(p_dealer_id, c.kind) k
      cross join lateral public.briefing_score(c.kind, c.event_at, c.value_cents, c.contact_reachable, p_now, p_dealer_id) s
     where c.dealer_id = p_dealer_id and k.enabled and (v_all or c.owner_user_id = p_user_id or c.owner_user_id is null)
     order by c.lead_id, s.score desc) x
  order by x.score desc, x.lead_id
  limit least(greatest(coalesce(p_limit, 7), 1), 25);
end $$;

create or replace function public.mcp_find_leads(p_dealer_id uuid, p_user_id uuid, p_role text, p_query text, p_limit int default 5)
returns table (lead_id uuid, name text, stage text, last_activity_at timestamptz)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public.mcp_require(p_role, 'leads:read');
  return query
  select l.id, concat_ws(' ', c.first_name, c.last_name), l.stage, greatest(l.last_inbound_at, l.last_outbound_at, l.created_at)
    from public.leads l join public.contacts c on c.id = l.contact_id
   where l.dealer_id = p_dealer_id and length(btrim(coalesce(p_query, ''))) >= 2
     and ('leads:read_all' = any (public.mcp_role_scopes(p_role)) or l.assigned_to is null or l.assigned_to = p_user_id)
     and (concat_ws(' ', c.first_name, c.last_name) ilike '%' || replace(replace(btrim(p_query), '%', ''), '_', '') || '%')
   order by (l.stage in ('won','lost')), greatest(l.last_inbound_at, l.last_outbound_at, l.created_at) desc nulls last
   limit least(greatest(coalesce(p_limit, 5), 1), 10);
end $$;

create or replace function public.mcp_get_lead(p_dealer_id uuid, p_user_id uuid, p_role text, p_lead_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare l public.leads;
begin
  perform public.mcp_require(p_role, 'leads:read');
  l := public.mcp_visible_lead(p_dealer_id, p_user_id, p_role, p_lead_id);
  return (
    select jsonb_build_object(
      'lead', jsonb_build_object('id', l.id, 'stage', l.stage, 'assigned_to', l.assigned_to, 'value_cents', l.value_cents,
                                 'last_inbound_at', l.last_inbound_at, 'last_outbound_at', l.last_outbound_at, 'lease_end_on', l.lease_end_on),
      'contact', jsonb_build_object('name', concat_ws(' ', c.first_name, c.last_name),
                                    'phone_last4', right(c.phone_e164, 4), 'has_email', coalesce(c.email, '') <> ''),
      'reachable', jsonb_build_object(
        'dnc_all_channels', exists (select 1 from public.contact_dnc x where x.contact_id = c.id and x.cleared_at is null and x.channel is null),
        'marketing_channel', public.contact_consented_channel(c.id, 'marketing'),
        'conversational_channel', public.contact_consented_channel(c.id, 'conversational')),
      'vehicle', (select jsonb_build_object('vin', v.vin, 'year', v.year, 'make', v.make, 'model', v.model, 'status', v.status, 'price_cents', v.price_cents)
                    from public.vehicles v where v.id = l.vehicle_id),
      'facts', coalesce((select jsonb_object_agg(f.fact_key, f.value) from public.customer_facts f where f.lead_id = l.id and f.superseded_at is null), '{}'::jsonb),
      'recent_messages', coalesce((select jsonb_agg(jsonb_build_object('at', m.created_at, 'direction', m.direction, 'author', m.author_kind, 'channel', m.channel, 'body', left(m.body, 300)) order by m.created_at desc)
                                     from (select * from public.messages m where m.lead_id = l.id order by m.created_at desc limit 10) m), '[]'::jsonb),
      'open_followups', (select count(*) from public.followup_plans p where p.lead_id = l.id and p.status = any (public.followup_active_statuses())),
      'drafts_awaiting_review', (select count(*) from public.outbound_drafts d where d.lead_id = l.id and d.status in ('awaiting_review','held')),
      'last_stage_change', (select jsonb_build_object('activity_id', a.id, 'from', a.from_stage, 'to', a.to_stage, 'actor', a.actor_kind, 'at', a.created_at, 'undoable', a.undone_at is null)
                              from public.lead_activities a where a.lead_id = l.id and a.kind = 'stage_changed' order by a.created_at desc limit 1))
      from public.contacts c where c.id = l.contact_id);
end $$;

create or replace function public.mcp_move_stage(p_dealer_id uuid, p_user_id uuid, p_role text, p_lead_id uuid, p_stage text, p_reason text default null)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare l public.leads; v_decision text; v_act uuid;
begin
  perform public.mcp_require(p_role, 'leads:write');
  l := public.mcp_visible_lead(p_dealer_id, p_user_id, p_role, p_lead_id);
  v_decision := public.apply_lead_stage(p_dealer_id, p_lead_id, p_stage, 'human', null, coalesce(p_reason, 'via MCP / text'),
                                        jsonb_build_object('via', 'mcp'), 0.85, p_user_id);
  select id into v_act from public.lead_activities where lead_id = p_lead_id and kind = 'stage_changed' order by created_at desc, id desc limit 1;
  return jsonb_build_object('decision', v_decision, 'from', l.stage, 'to', p_stage, 'undo_activity_id', case when v_decision = 'applied' then v_act end);
end $$;

create or replace function public.mcp_create_task(p_dealer_id uuid, p_user_id uuid, p_role text, p_lead_id uuid, p_title text,
  p_due_at timestamptz, p_assign_to uuid default null, p_now timestamptz default now())
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare l public.leads; v_assignee uuid := coalesce(p_assign_to, p_user_id); v_id uuid;
begin
  perform public.mcp_require(p_role, 'tasks:write');
  l := public.mcp_visible_lead(p_dealer_id, p_user_id, p_role, p_lead_id);
  if length(btrim(coalesce(p_title, ''))) < 3 then raise exception 'invalid: title too short' using errcode = '22023'; end if;
  if p_due_at < p_now - interval '5 minutes' or p_due_at > p_now + interval '90 days' then raise exception 'invalid: due_at must be within 90 days' using errcode = '22023'; end if;
  if v_assignee <> p_user_id and not ('leads:read_all' = any (public.mcp_role_scopes(p_role))) then
    raise exception 'forbidden: only managers assign tasks to others' using errcode = '42501';
  end if;
  if not exists (select 1 from public.dealer_members m where m.user_id = v_assignee and m.dealer_id = p_dealer_id) then
    raise exception 'invalid: assignee is not a member' using errcode = '22023';
  end if;
  insert into public.followups (dealer_id, lead_id, assigned_to, kind, due_at, reason, status)
  values (p_dealer_id, l.id, v_assignee, 'rep_callback', p_due_at, left(btrim(p_title), 200), 'scheduled') returning id into v_id;
  return v_id;
end $$;

create or replace function public.mcp_search_inventory(p_dealer_id uuid, p_role text, p_make text default null, p_model text default null,
  p_year_min int default null, p_year_max int default null, p_max_price_cents bigint default null, p_body_style text default null,
  p_condition text default null, p_limit int default 5)
returns table (vin text, year int, make text, model text, "trim" text, condition text, mileage int, status text, price_cents bigint)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public.mcp_require(p_role, 'inventory:read');
  return query
  select v.vin, v.year, v.make, v.model, v.trim, v.condition, v.mileage, v.status, v.price_cents
    from public.vehicles v
   where v.dealer_id = p_dealer_id and v.status in ('available','in_transit')
     and (p_make is null or v.make ilike p_make) and (p_model is null or v.model ilike '%' || p_model || '%')
     and (p_year_min is null or v.year >= p_year_min) and (p_year_max is null or v.year <= p_year_max)
     and (p_max_price_cents is null or v.price_cents <= p_max_price_cents)
     and (p_body_style is null or v.body_style ilike p_body_style) and (p_condition is null or v.condition = p_condition)
   order by v.price_cents nulls last, v.year desc
   limit least(greatest(coalesce(p_limit, 5), 1), 20);
end $$;

-- Customer messages from MCP/text are ALWAYS drafts (awaiting_review). Hard compliance vetoes refuse to create one.
create or replace function public.mcp_draft_message(p_dealer_id uuid, p_user_id uuid, p_role text, p_lead_id uuid, p_body text,
  p_channel public.channel_kind default null, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare l public.leads; r record; v_kind public.send_kind; v_dec public.send_decision; v_id uuid; v_last_in timestamptz;
begin
  perform public.mcp_require(p_role, 'drafts:write');
  l := public.mcp_visible_lead(p_dealer_id, p_user_id, p_role, p_lead_id);
  if length(btrim(coalesce(p_body, ''))) = 0 or length(p_body) > 1000 then raise exception 'invalid: body must be 1-1000 characters' using errcode = '22023'; end if;
  select * into r from public.pick_send_route(p_dealer_id, l.contact_id, p_channel);
  if r.channel is null then return jsonb_build_object('ok', false, 'code', 'unreachable', 'message', 'No usable channel (no address, no active number, or opted out).'); end if;
  select max(created_at) into v_last_in from public.messages where contact_id = l.contact_id and channel = r.channel and direction = 'inbound';
  v_kind := case when v_last_in > p_now - interval '24 hours' then 'reply' else 'followup' end;
  v_dec := public.can_send(p_dealer_id, l.contact_id, r.channel, 'conversational', v_kind, r.number_id, p_body, l.id, 'human', false, false, null, p_now);
  if v_dec.verdict = 'veto' and v_dec.code in ('dnc_active','no_consent','no_address','contact_anonymized','cold_requires_marketing') then
    return jsonb_build_object('ok', false, 'code', v_dec.code, 'message', v_dec.reason);
  end if;
  insert into public.outbound_drafts (dealer_id, lead_id, contact_id, channel, number_id, actor, purpose, kind, body_ai, status, expected_context_version, evidence)
  values (p_dealer_id, l.id, l.contact_id, r.channel, r.number_id, 'human', 'conversational', v_kind, btrim(p_body), 'awaiting_review', l.context_version,
          jsonb_build_object('source', 'mcp', 'requested_by', p_user_id))
  returning id into v_id;
  return jsonb_build_object('ok', true, 'draft_id', v_id, 'status', 'awaiting_review', 'channel', r.channel,
                            'compliance', jsonb_build_object('verdict', v_dec.verdict, 'code', v_dec.code, 'not_before', v_dec.not_before),
                            'note', 'Saved as a draft. A person must approve it in SalesOS before anything is sent.');
end $$;

-- =====================================================================================
-- PART K. SCHEDULING (extends the guarded pg_cron block) + kickers
-- =====================================================================================
create or replace function public.kick_outbound_sweeper() returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if exists (select 1 from public.outbound_drafts where status in ('held','delayed') and release_at is not null and release_at <= now())
     or exists (select 1 from public.followup_plans where status in ('scheduled','postponed') and due_at <= now()) then
    perform public.invoke_edge_function('outbound-sweeper');
  end if;
end $$;

create or replace function public.kick_embed_worker() returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if exists (select 1 from public.embed_queue where not_before <= now() and locked_at is null and attempts < 8) then
    perform public.invoke_edge_function('embed-worker');
  end if;
end $$;

do $cron$
begin
  if to_regclass('cron.job') is null then raise notice 'pg_cron not available; phase-3 schedules skipped'; return; end if;
  perform cron.schedule('salesos-followup-generate', '*/5 * * * *', $$select public.generate_followup_plans()$$);
  perform cron.schedule('salesos-embed',             '* * * * *',   $$select public.kick_embed_worker()$$);
exception when others then
  raise notice 'pg_cron scheduling skipped: %', sqlerrm;
end
$cron$;

-- =====================================================================================
-- PART L. RLS + GRANTS
-- =====================================================================================
do $rls$
declare t text;
  tenant_tables text[] := array['dealer_briefing_kind_config','kb_documents','kb_chunks','vehicle_listing_chunks','embed_queue',
    'draft_citations','customer_facts','vehicle_events','customer_vehicles','followup_plans','classifications',
    'staff_identities','mcp_api_keys','mcp_audit_log'];
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

-- managers curate the knowledge base from the app (chunking + embedding happen server-side via triggers/worker)
drop policy if exists kb_documents_manager_write on public.kb_documents;
create policy kb_documents_manager_write on public.kb_documents for all to authenticated
  using (public.is_dealer_member(dealer_id, array['owner','admin','manager']))
  with check (public.is_dealer_member(dealer_id, array['owner','admin','manager']));
grant insert, update, delete on public.kb_documents to authenticated;

drop policy if exists dealer_briefing_kind_config_admin_write on public.dealer_briefing_kind_config;
create policy dealer_briefing_kind_config_admin_write on public.dealer_briefing_kind_config for all to authenticated
  using (public.is_dealer_member(dealer_id, array['owner','admin','manager']))
  with check (public.is_dealer_member(dealer_id, array['owner','admin','manager']));
grant insert, update, delete on public.dealer_briefing_kind_config to authenticated;

-- staff identities: owners/admins manage the allow-list
drop policy if exists staff_identities_admin_write on public.staff_identities;
create policy staff_identities_admin_write on public.staff_identities for all to authenticated
  using (public.is_dealer_member(dealer_id, array['owner','admin']))
  with check (public.is_dealer_member(dealer_id, array['owner','admin']));
grant insert, update on public.staff_identities to authenticated;
-- staff phone numbers are personal data: a member sees their own identity; owners/admins see the whole allow-list
drop policy if exists staff_identities_member_select on public.staff_identities;
drop policy if exists staff_identities_self_select on public.staff_identities;
create policy staff_identities_self_select on public.staff_identities for select to authenticated
  using (user_id = auth.uid() and public.is_dealer_member(dealer_id));

-- API keys: only owners/admins can see them, and never the hash
drop policy if exists mcp_api_keys_member_select on public.mcp_api_keys;
drop policy if exists mcp_api_keys_admin_select on public.mcp_api_keys;
create policy mcp_api_keys_admin_select on public.mcp_api_keys for select to authenticated
  using (public.is_dealer_member(dealer_id, array['owner','admin']));
revoke select on public.mcp_api_keys from authenticated;
grant select (id, dealer_id, acting_user_id, name, key_prefix, role, scopes, created_by, created_at, last_used_at, expires_at, revoked_at) on public.mcp_api_keys to authenticated;
drop policy if exists mcp_audit_log_member_select on public.mcp_audit_log;
drop policy if exists mcp_audit_log_admin_select on public.mcp_audit_log;
create policy mcp_audit_log_admin_select on public.mcp_audit_log for select to authenticated
  using (public.is_dealer_member(dealer_id, array['owner','admin','manager']));
-- embed_queue is plumbing
drop policy if exists embed_queue_member_select on public.embed_queue;
revoke select on public.embed_queue from authenticated;

do $grants$
declare r record;
begin
  -- service role only
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = any (array[
              'build_briefing_items','enqueue_embedding','kb_rechunk','kb_documents_after_write','vehicles_sync_listing_chunk',
              'claim_embed_jobs','complete_embed_job','fail_embed_job','defer_embed_jobs','requeue_embeddings_for_model',
              'record_draft_citations','upsert_customer_fact','cancel_followup_plans','followups_stop_on_inbound','followups_stop_on_consent',
              'followups_stop_on_stage','vehicles_track_events','contact_consented_channel','generate_followup_plans','claim_due_followups',
              'record_followup_outcome','followup_to_inbox','pick_send_route','get_gate_context','finalize_draft_send',
              'apply_classification','record_classification','record_classification_failure','set_lead_stage_human','classifications_stale_on_inbound',
              'verify_mcp_api_key','resolve_staff_sender','mcp_audit','mcp_visible_lead','mcp_list_attention','mcp_find_leads','mcp_get_lead',
              'mcp_move_stage','mcp_create_task','mcp_search_inventory','mcp_draft_message','kick_embed_worker','kick_outbound_sweeper'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
  -- callable by signed-in staff (each checks membership/role internally via auth.uid())
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname = any (array[
              'match_kb','accept_classification','reject_classification','override_classification','undo_stage_change',
              'create_mcp_api_key','revoke_mcp_api_key','require_staff'])
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated, service_role', r.sig);
  end loop;
end
$grants$;
revoke select on public.v_lead_timeline from anon;
grant select on public.v_lead_timeline to authenticated;
