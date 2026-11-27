-- SalesOS AI package, adapted for the live salesos project: lives in schema salesos_ai (additive; no existing object touched).
-- Source: 20261129090000_offline_gaps.sql with public. -> salesos_ai.
set search_path to salesos_ai, extensions, public;
-- =====================================================================================
-- Phase 5 (offline gaps): durable keyword-reply outbox, email suppression, customer-fact tool RPCs,
-- WhatsApp template compliance, staff phone verification.  No provider is contacted from SQL.
-- =====================================================================================

-- =====================================================================================
-- PART S. KEYWORD-REPLY OUTBOX: a failed STOP/START/HELP confirmation is retried with backoff, never sent twice
-- =====================================================================================
alter table salesos_ai.keyword_replies add column if not exists number_id uuid references salesos_ai.channel_numbers(id) on delete set null;
alter table salesos_ai.keyword_replies add column if not exists status text not null default 'pending';
alter table salesos_ai.keyword_replies add column if not exists attempts int not null default 0;
alter table salesos_ai.keyword_replies add column if not exists next_attempt_at timestamptz not null default now();
alter table salesos_ai.keyword_replies add column if not exists locked_at timestamptz;
alter table salesos_ai.keyword_replies add column if not exists last_error text;
alter table salesos_ai.keyword_replies add column if not exists finished_at timestamptz;
do $$ begin
  alter table salesos_ai.keyword_replies add constraint keyword_replies_status_ck
    check (status in ('pending','sending','sent','gave_up','carrier_blocked','unknown','expired'));
exception when duplicate_object then null; end $$;
update salesos_ai.keyword_replies set status = 'sent', finished_at = coalesce(finished_at, created_at) where sent_message_id is not null and status = 'pending';
create index if not exists keyword_replies_due_idx on salesos_ai.keyword_replies (next_attempt_at) where status in ('pending','sending');

-- the number and first due time come from the triggering message / the caller's clock (apply_inbound_keyword stays untouched)
create or replace function salesos_ai.keyword_replies_defaults() returns trigger language plpgsql as $$
begin
  new.number_id := coalesce(new.number_id, (select m.number_id from salesos_ai.messages m where m.id = new.trigger_message_id));
  new.next_attempt_at := new.created_at;
  return new;
end $$;
drop trigger if exists keyword_replies_defaults_trg on salesos_ai.keyword_replies;
create trigger keyword_replies_defaults_trg before insert on salesos_ai.keyword_replies for each row execute function salesos_ai.keyword_replies_defaults();

-- Retry policy. A STOP confirmation must stay inside the 5-minute window the FCC allows for the single confirmation,
-- so it retries quickly and then expires instead of arriving late. START/HELP are not time-critical but still expire.
create or replace function salesos_ai.keyword_reply_policy(p_kind text)
returns table (max_attempts int, window_secs int, backoff_secs int[]) language sql immutable as $$
  select 4,
         case p_kind when 'stop' then 300 else 3600 end,
         case p_kind when 'stop' then array[15, 45, 120] else array[60, 300, 1200] end
$$;

-- A crashed worker's claim is reclaimable after the lease; a STOP confirmation has a minute (its whole window is five).
create or replace function salesos_ai.keyword_reply_lease(p_kind text) returns interval language sql immutable as $$
  select case when p_kind = 'stop' then interval '60 seconds' else interval '5 minutes' end
$$;

-- Claim ONE due reply (or return nothing). Crash safety: a 'sending' row older than 5 min is reclaimable; the send-attempt
-- key kw:<id> then decides (already_sent => no second message; pending on Twilio/Meta => 'unknown' => a person checks).
create or replace function salesos_ai.begin_keyword_reply(p_id uuid, p_now timestamptz default now())
returns table (reply_id uuid, kind text, dealer_id uuid, contact_id uuid, number_id uuid, channel salesos_ai.channel_kind, attempts int, dealer_name text, main_phone text)
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
#variable_conflict use_column
declare k salesos_ai.keyword_replies; pol record; v_stale boolean;
begin
  select * into k from salesos_ai.keyword_replies r where r.id = p_id for update skip locked;
  if k.id is null or k.sent_message_id is not null then return; end if;
  if not ((k.status = 'pending' and k.next_attempt_at <= p_now) or (k.status = 'sending' and k.locked_at < p_now - salesos_ai.keyword_reply_lease(k.kind))) then return; end if;
  select * into pol from salesos_ai.keyword_reply_policy(k.kind);
  v_stale := p_now > k.created_at + make_interval(secs => pol.window_secs)
          or (k.kind = 'stop'  and exists (select 1 from salesos_ai.consent_events c where c.contact_id = k.contact_id and c.action = 'grant' and c.channel = k.channel and c.created_at > coalesce(
                (select e.created_at from salesos_ai.consent_events e where e.id = k.consent_event_id), k.created_at)))
          or (k.kind = 'start' and exists (select 1 from salesos_ai.contact_dnc x where x.contact_id = k.contact_id and x.cleared_at is null and (x.channel is null or x.channel = k.channel)));
  if v_stale then
    update salesos_ai.keyword_replies set status = 'expired', finished_at = p_now, last_error = coalesce(last_error, 'window_elapsed_or_superseded') where id = k.id;
    return;
  end if;
  if k.attempts >= pol.max_attempts then
    update salesos_ai.keyword_replies set status = 'gave_up', finished_at = p_now where id = k.id;
    return;
  end if;
  update salesos_ai.keyword_replies set status = 'sending', attempts = keyword_replies.attempts + 1, locked_at = p_now where id = k.id;
  reply_id := k.id; kind := k.kind; dealer_id := k.dealer_id; contact_id := k.contact_id; number_id := k.number_id; channel := k.channel; attempts := k.attempts + 1;
  select d.name, d.main_phone into dealer_name, main_phone from salesos_ai.dealers d where d.id = k.dealer_id;
  return next;
end $$;

create or replace function salesos_ai.claim_keyword_replies(p_limit int default 20, p_now timestamptz default now())
returns table (reply_id uuid, kind text, dealer_id uuid, contact_id uuid, number_id uuid, channel salesos_ai.channel_kind, attempts int, dealer_name text, main_phone text)
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
#variable_conflict use_column
declare r record;
begin
  for r in select id from salesos_ai.keyword_replies
            where sent_message_id is null and ((status = 'pending' and next_attempt_at <= p_now) or (status = 'sending' and locked_at < p_now - salesos_ai.keyword_reply_lease(kind)))
            order by next_attempt_at limit greatest(p_limit, 1) for update skip locked
  loop
    return query select * from salesos_ai.begin_keyword_reply(r.id, p_now);
  end loop;
end $$;

-- Outcome of one attempt. Returns the row's status afterwards. Idempotent: only a 'sending' row is touched.
create or replace function salesos_ai.finish_keyword_reply(p_id uuid, p_ok boolean, p_provider_message_id text default null, p_error text default null,
  p_retryable boolean default false, p_body text default null, p_now timestamptz default now())
returns text language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare k salesos_ai.keyword_replies; pol record; v_status text; v_lead uuid;
begin
  select * into k from salesos_ai.keyword_replies where id = p_id for update;
  if k.id is null then raise exception 'keyword reply % not found', p_id; end if;
  if k.status <> 'sending' then return k.status; end if;
  select * into pol from salesos_ai.keyword_reply_policy(k.kind);
  if p_ok then
    perform salesos_ai.record_system_message(k.number_id, k.contact_id, coalesce(p_body, ''), p_provider_message_id, 'sent', k.id, null, p_now);
    update salesos_ai.keyword_replies set status = 'sent', finished_at = p_now, last_error = null, locked_at = null where id = k.id;
    return 'sent';
  end if;
  v_status := case
    when p_error in ('recipient_opted_out','email_suppressed') then 'carrier_blocked'   -- the carrier (or a bounce) already closed this recipient: expected, nothing to chase
    when p_error = 'send_outcome_unknown' then 'unknown'                   -- may have been delivered: never auto-resend
    when p_retryable and k.attempts < pol.max_attempts and p_now + make_interval(secs => pol.backoff_secs[least(k.attempts, cardinality(pol.backoff_secs))]) <= k.created_at + make_interval(secs => pol.window_secs) then 'pending'
    else 'gave_up' end;
  if v_status = 'pending' then
    update salesos_ai.keyword_replies set status = 'pending', last_error = left(p_error, 120), locked_at = null,
           next_attempt_at = p_now + make_interval(secs => pol.backoff_secs[least(k.attempts, cardinality(pol.backoff_secs))]) where id = k.id;
    return 'pending';
  end if;
  perform salesos_ai.record_system_message(k.number_id, k.contact_id, coalesce(p_body, ''), null, 'failed', null, p_error, p_now);
  update salesos_ai.keyword_replies set status = v_status, finished_at = p_now, last_error = left(p_error, 120), locked_at = null where id = k.id;
  if v_status in ('gave_up','unknown') then
    select l.id into v_lead from salesos_ai.leads l where l.contact_id = k.contact_id order by l.created_at desc limit 1;
    insert into salesos_ai.agent_inbox_items (dealer_id, lead_id, kind, priority, title, summary, payload)
    values (k.dealer_id, v_lead, 'send_failed', 2, format('%s confirmation could not be sent', upper(k.kind)),
            case when v_status = 'unknown' then 'The send may or may not have reached the customer. Check the provider log before doing anything.'
                 else 'Retries ran out. The opt-out/opt-in itself is recorded; only the confirmation text was not delivered.' end,
            jsonb_build_object('keyword_reply_id', k.id, 'kind', k.kind, 'error', p_error))
    on conflict (lead_id, kind) where status = 'open' and lead_id is not null do nothing;
  end if;
  return v_status;
end $$;

create or replace function salesos_ai.kick_keyword_reply_worker() returns void language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
begin
  if exists (select 1 from salesos_ai.keyword_replies where sent_message_id is null and ((status = 'pending' and next_attempt_at <= now()) or (status = 'sending' and locked_at < now() - salesos_ai.keyword_reply_lease(kind)))) then
    perform salesos_ai.invoke_edge_function('keyword-reply-worker');
  end if;
end $$;

-- =====================================================================================
-- PART T. EMAIL BOUNCES AND THE SUPPRESSION LIST
-- =====================================================================================
alter table salesos_ai.dealer_settings add column if not exists email_soft_bounce_limit int not null default 3 check (email_soft_bounce_limit between 1 and 10);
alter table salesos_ai.dealer_settings add column if not exists email_soft_bounce_window_days int not null default 14 check (email_soft_bounce_window_days between 1 and 90);

create table if not exists salesos_ai.email_bounce_events (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references salesos_ai.dealers(id) on delete cascade,
  contact_id uuid references salesos_ai.contacts(id) on delete set null,
  message_id uuid references salesos_ai.messages(id) on delete set null,
  email text not null,
  kind text not null check (kind in ('hard','soft')),
  diagnostic text,
  provider_event_id text,
  occurred_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create unique index if not exists email_bounce_events_event_uq on salesos_ai.email_bounce_events (provider_event_id) where provider_event_id is not null;
create index if not exists email_bounce_events_addr_idx on salesos_ai.email_bounce_events (dealer_id, email, occurred_at desc);

create table if not exists salesos_ai.email_suppressions (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references salesos_ai.dealers(id) on delete cascade,
  email text not null check (email = lower(btrim(email))),
  reason text not null check (reason in ('hard_bounce','soft_bounce_limit','provider_suppressed','manual')),
  source_event_id uuid references salesos_ai.email_bounce_events(id) on delete set null,
  note text,
  created_by uuid,
  created_at timestamptz not null default now(),
  cleared_at timestamptz, cleared_by uuid, cleared_note text
);
create unique index if not exists email_suppressions_live_uq on salesos_ai.email_suppressions (dealer_id, email) where cleared_at is null;

create or replace function salesos_ai.is_email_suppressed(p_dealer_id uuid, p_email text) returns boolean
language sql stable security definer set search_path = salesos_ai, pg_temp as $$
  select exists (select 1 from salesos_ai.email_suppressions where dealer_id = p_dealer_id and email = lower(btrim(p_email)) and cleared_at is null)
$$;

-- One bounce notification. Hard => suppress at once. Soft (transient / undetermined) => count toward the dealer's limit within
-- the window; a later successful delivery to the contact, or an operator clearing the address, resets the count.
-- Idempotent on the provider event id (webhook retries).
create or replace function salesos_ai.record_email_bounce(p_provider_message_id text, p_kind text, p_email text default null, p_diagnostic text default null,
  p_provider_event_id text default null, p_dealer_id uuid default null, p_now timestamptz default now())
returns table (recorded boolean, suppressed boolean, reason text, soft_count int)
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
#variable_conflict use_column
declare m salesos_ai.messages; v_dealer uuid; v_email text; v_contact uuid; v_ev uuid; s salesos_ai.dealer_settings; v_since timestamptz; v_n int; v_last_ok timestamptz; v_reason text;
begin
  if p_kind not in ('hard','soft') then raise exception 'invalid bounce kind %', p_kind using errcode = '22023'; end if;
  select * into m from salesos_ai.messages where channel = 'email' and provider_message_id = p_provider_message_id and direction = 'outbound';
  v_dealer := coalesce(m.dealer_id, p_dealer_id);
  v_contact := m.contact_id;
  v_email := lower(btrim(coalesce(p_email, (select c.email from salesos_ai.contacts c where c.id = m.contact_id))));
  if v_dealer is null or coalesce(v_email, '') = '' then recorded := false; suppressed := false; reason := 'unknown_recipient'; soft_count := 0; return next; return; end if;
  if p_provider_event_id is not null and exists (select 1 from salesos_ai.email_bounce_events where provider_event_id = p_provider_event_id) then
    recorded := false; suppressed := salesos_ai.is_email_suppressed(v_dealer, v_email);
    select es.reason into reason from salesos_ai.email_suppressions es where es.dealer_id = v_dealer and es.email = v_email and es.cleared_at is null;
    soft_count := 0; return next; return;
  end if;
  insert into salesos_ai.email_bounce_events (dealer_id, contact_id, message_id, email, kind, diagnostic, provider_event_id, occurred_at)
  values (v_dealer, v_contact, m.id, v_email, p_kind, left(p_diagnostic, 300), p_provider_event_id, p_now) returning id into v_ev;
  recorded := true;
  select * into s from salesos_ai.dealer_settings where dealer_id = v_dealer;
  -- soft count: inside the window, after the last good delivery to this contact and after the last time an operator cleared the address
  select max(x.delivered_at) into v_last_ok from salesos_ai.messages x where x.contact_id = v_contact and x.channel = 'email' and x.direction = 'outbound' and x.delivered_at is not null and x.delivered_at <= p_now;
  v_since := greatest(p_now - make_interval(days => coalesce(s.email_soft_bounce_window_days, 14)), coalesce(v_last_ok, '-infinity'),
                      coalesce((select max(es.cleared_at) from salesos_ai.email_suppressions es where es.dealer_id = v_dealer and es.email = v_email), '-infinity'));
  select count(*) into v_n from salesos_ai.email_bounce_events b where b.dealer_id = v_dealer and b.email = v_email and b.kind = 'soft' and b.occurred_at > v_since;
  soft_count := v_n;
  v_reason := case when p_kind = 'hard' then 'hard_bounce' when v_n >= coalesce(s.email_soft_bounce_limit, 3) then 'soft_bounce_limit' end;
  if v_reason is not null then
    insert into salesos_ai.email_suppressions (dealer_id, email, reason, source_event_id, note) values (v_dealer, v_email, v_reason, v_ev, left(p_diagnostic, 300))
    on conflict (dealer_id, email) where cleared_at is null do nothing;
  end if;
  suppressed := salesos_ai.is_email_suppressed(v_dealer, v_email);
  reason := (select es.reason from salesos_ai.email_suppressions es where es.dealer_id = v_dealer and es.email = v_email and es.cleared_at is null);
  return next;
end $$;

-- Resend told us it suppressed the address (or an operator adds one by hand)
create or replace function salesos_ai.suppress_email(p_dealer_id uuid, p_email text, p_reason text default 'manual', p_note text default null, p_actor uuid default null)
returns boolean language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare v_actor uuid; v_n int;
begin
  if p_reason not in ('manual','provider_suppressed') then raise exception 'invalid reason' using errcode = '22023'; end if;
  if p_reason = 'manual' then v_actor := salesos_ai.require_staff(p_dealer_id, p_actor, array['owner','admin','manager','sales','bdc']); end if;
  insert into salesos_ai.email_suppressions (dealer_id, email, reason, note, created_by) values (p_dealer_id, lower(btrim(p_email)), p_reason, left(p_note, 300), v_actor)
  on conflict (dealer_id, email) where cleared_at is null do nothing;
  get diagnostics v_n = row_count;
  return v_n > 0;
end $$;

-- Only a manager can put a bounced address back in play (typo fixed, mailbox restored). Needs a reason; history is kept.
create or replace function salesos_ai.clear_email_suppression(p_dealer_id uuid, p_email text, p_note text, p_actor uuid default null)
returns boolean language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare v_actor uuid; v_n int;
begin
  v_actor := salesos_ai.require_staff(p_dealer_id, p_actor, array['owner','admin','manager']);
  if length(btrim(coalesce(p_note, ''))) < 8 then raise exception 'a reason of at least 8 characters is required' using errcode = '22023'; end if;
  update salesos_ai.email_suppressions set cleared_at = now(), cleared_by = v_actor, cleared_note = left(p_note, 300)
   where dealer_id = p_dealer_id and email = lower(btrim(p_email)) and cleared_at is null;
  get diagnostics v_n = row_count;
  return v_n > 0;
end $$;

-- The send gate. (Same definition as before plus the suppression veto right after the address check.)
create or replace function salesos_ai.can_send(
  p_dealer_id uuid, p_contact_id uuid, p_channel salesos_ai.channel_kind,
  p_purpose salesos_ai.consent_purpose, p_kind salesos_ai.send_kind, p_number_id uuid,
  p_body text default null, p_lead_id uuid default null, p_actor text default 'ai',
  p_is_template boolean default false, p_commit boolean default false,
  p_idempotency_key text default null, p_now timestamptz default now()
) returns salesos_ai.send_decision
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare
  s salesos_ai.dealer_settings; c salesos_ai.contacts; d salesos_ai.dealers; n salesos_ai.channel_numbers; l salesos_ai.leads;
  v_tz text; v_state char(2); v_start time; v_end time; v_sun time; sq salesos_ai.state_quiet_hours;
  v_obeys_quiet boolean; v_open timestamptz;
  v_last_in timestamptz; v_window int;
  v_cap int; v_used int; v_day_start timestamptz; v_next_day timestamptz;
  v_norm text; v_tokens text[]; v_similar int; v_exempt boolean;
  v_res uuid; v_next timestamptz; v_existing salesos_ai.send_reservations;
  v_consent_ok boolean;
begin
  if p_commit then
    perform pg_advisory_xact_lock(hashtextextended(p_number_id::text, 0));
    if p_idempotency_key is not null then
      select * into v_existing from salesos_ai.send_reservations
       where dealer_id = p_dealer_id and idempotency_key = p_idempotency_key and status in ('reserved','sent');
      if found then
        return salesos_ai._decision('allow','idempotent_replay','Same idempotency key already reserved.', null, v_existing.id);
      end if;
    end if;
  end if;

  select * into d from salesos_ai.dealers where id = p_dealer_id;
  select * into s from salesos_ai.dealer_settings where dealer_id = p_dealer_id;
  if d.id is null or s.dealer_id is null then
    return salesos_ai._decision('veto','dealer_settings_missing','Dealer or dealer_settings row missing.');
  end if;
  select * into c from salesos_ai.contacts where id = p_contact_id and dealer_id = p_dealer_id;
  if c.id is null then return salesos_ai._decision('veto','contact_not_found','Contact not found for this dealer.'); end if;
  if c.is_anonymized then return salesos_ai._decision('veto','contact_anonymized','Contact was anonymized; nothing may be sent.'); end if;
  select * into n from salesos_ai.channel_numbers where id = p_number_id and dealer_id = p_dealer_id;
  if n.id is null then return salesos_ai._decision('veto','number_not_found','Sending identity not found for this dealer.'); end if;
  if n.channel <> p_channel then return salesos_ai._decision('veto','number_channel_mismatch','Sending identity belongs to a different channel.'); end if;
  if n.status <> 'active' then return salesos_ai._decision('veto','number_inactive', format('Sending identity is %s.', n.status)); end if;
  if (p_channel in ('sms','whatsapp') and coalesce(c.phone_e164,'') = '') or (p_channel = 'email' and coalesce(c.email,'') = '') then
    return salesos_ai._decision('veto','no_address','Contact has no address for this channel.');
  end if;
  -- 0b) email suppression list (hard bounce / soft-bounce limit / provider suppression): never mail a dead address
  if p_channel = 'email' and exists (select 1 from salesos_ai.email_suppressions es
                                      where es.dealer_id = p_dealer_id and es.email = lower(btrim(c.email)) and es.cleared_at is null) then
    return salesos_ai._decision('veto','email_suppressed','This address is on the suppression list (bounced). Do not email it.');
  end if;

  if p_lead_id is not null then
    select * into l from salesos_ai.leads where id = p_lead_id and dealer_id = p_dealer_id;
    if l.id is null or l.contact_id <> p_contact_id then
      return salesos_ai._decision('veto','lead_contact_mismatch','Lead does not belong to this contact/dealer.');
    end if;
    if p_actor = 'ai' and (l.force_human or (l.bot_silenced_until is not null and l.bot_silenced_until > p_now)) then
      return salesos_ai._decision('veto','human_owned','A person owns this conversation; the assistant is silenced.');
    end if;
  end if;

  -- 1) DNC: irrevocable, checked before anything about consent
  if exists (select 1 from salesos_ai.contact_dnc x where x.contact_id = p_contact_id and x.cleared_at is null
                and (x.channel is null or x.channel = p_channel)) then
    return salesos_ai._decision('veto','dnc_active','Contact opted out. Only the contact can re-opt-in.');
  end if;

  -- 2) consent or reply window
  if p_kind = 'reply' then
    select max(created_at) into v_last_in from salesos_ai.messages
     where contact_id = p_contact_id and channel = p_channel and direction = 'inbound' and created_at <= p_now;
    v_window := case when p_channel = 'whatsapp' then least(24, s.reply_window_hours) else s.reply_window_hours end;
    if v_last_in is null or v_last_in < p_now - make_interval(hours => v_window) then
      return salesos_ai._decision('veto', case when p_channel = 'whatsapp' then 'wa_window_closed' else 'reply_window_closed' end,
        format('No inbound %s from this contact in the last %s h; a reply is not allowed. Use an approved template (WhatsApp) or a consented follow-up.', p_channel, v_window),
        null, null, jsonb_build_object('last_inbound_at', v_last_in, 'requires_template', p_channel = 'whatsapp'));
    end if;
  else
    if p_kind = 'cold' and p_purpose <> 'marketing' then
      return salesos_ai._decision('veto','cold_requires_marketing','First-touch outreach needs marketing-purpose consent.');
    end if;
    if not (p_channel = 'email' and not s.email_requires_consent) then
      select exists (select 1 from salesos_ai.contact_consent_state cs
                      where cs.contact_id = p_contact_id and cs.channel = p_channel and cs.status = 'granted' and cs.evidence_ok
                        and salesos_ai.purpose_rank(cs.purpose) >= salesos_ai.purpose_rank(p_purpose)) into v_consent_ok;
      if not v_consent_ok then
        return salesos_ai._decision('veto','no_consent', format('No valid %s consent on %s for this contact (grant needs provenance; marketing needs disclosure version).', p_purpose, p_channel));
      end if;
    end if;
  end if;

  -- 3) quiet hours at the RECIPIENT's local time (federal window intersected with state window)
  v_tz := coalesce(c.timezone, d.timezone);
  v_state := coalesce(c.state_code, d.state_code);
  v_start := s.quiet_start; v_end := s.quiet_end; v_sun := s.sunday_start;
  select * into sq from salesos_ai.state_quiet_hours where state_code = v_state;
  if sq.state_code is not null then
    v_start := greatest(v_start, sq.start_time); v_end := least(v_end, sq.end_time);
    v_sun := case when sq.sunday_start is null then v_sun else greatest(coalesce(v_sun, v_start), sq.sunday_start) end;
  end if;
  v_obeys_quiet := not ((p_kind = 'reply' and s.reply_ignores_quiet) or (p_kind = 'transactional' and s.transactional_ignores_quiet))
                   and p_channel <> 'email';
  if v_obeys_quiet then
    v_open := salesos_ai.next_window_open(p_now, v_tz, v_start, v_end, v_sun);
    if v_open > p_now then
      return salesos_ai._decision('delay','quiet_hours', format('Outside %s-%s recipient-local (%s). Retry at not_before.', v_start, v_end, v_tz), v_open,
                              null, jsonb_build_object('tz', v_tz, 'state', v_state));
    end if;
  end if;

  -- 4) warm-up / daily cap on non-reply traffic
  if p_kind <> 'reply' then
    v_cap := salesos_ai.number_daily_cap(p_number_id, p_now);
    if v_cap is not null then
      v_day_start := (((p_now at time zone d.timezone)::date)::timestamp) at time zone d.timezone;
      v_next_day  := ((((p_now at time zone d.timezone)::date + 1)::timestamp)) at time zone d.timezone;
      select count(*) into v_used from salesos_ai.send_reservations r
       where r.number_id = p_number_id and r.kind <> 'reply' and r.status in ('reserved','sent')
         and r.reserved_at >= v_day_start and r.reserved_at < v_next_day;
      if v_used >= v_cap then
        v_open := case when v_obeys_quiet then salesos_ai.next_window_open(v_next_day, v_tz, v_start, v_end, v_sun) else v_next_day end;
        return salesos_ai._decision('delay','daily_cap', format('Daily cap %s reached for this number (used %s).', v_cap, v_used), v_open,
                                null, jsonb_build_object('cap', v_cap, 'used', v_used));
      end if;
    end if;
  end if;

  -- 5) throttle + jitter: one send slot at a time per identity
  if n.next_allowed_at is not null and n.next_allowed_at > p_now then
    return salesos_ai._decision('delay','throttle','Per-number throttle; retry at not_before.', n.next_allowed_at);
  end if;

  -- 6) anti-template (free-form copy only; approved templates are exempt)
  if p_body is not null and not p_is_template then
    v_norm := salesos_ai.normalize_copy(p_body);
    v_exempt := length(v_norm) <= n.spin_allow_max_len or v_norm ~* n.spin_allow_regex;
    if not v_exempt then
      v_tokens := salesos_ai.copy_tokens(v_norm);
      select count(*) into v_similar from (
        select r.body_norm from salesos_ai.send_reservations r
         where r.number_id = p_number_id and r.status in ('reserved','sent') and r.body_norm is not null and not r.is_template
         order by r.reserved_at desc limit n.spin_window
      ) w where w.body_norm = v_norm or salesos_ai.jaccard(salesos_ai.copy_tokens(w.body_norm), v_tokens) >= n.spin_threshold;
      if v_similar >= n.spin_repetition then
        return salesos_ai._decision('veto','template_repetition',
          format('This copy is >=%s similar to %s recent messages from this number. Rewrite it in different words.', n.spin_threshold, v_similar),
          null, null, jsonb_build_object('similar', v_similar));
      end if;
    end if;
  end if;

  if not p_commit then
    return salesos_ai._decision('allow','ok','Would be allowed.', null, null,
      jsonb_build_object('tz', v_tz, 'cap', v_cap, 'used', v_used));
  end if;

  insert into salesos_ai.send_reservations(dealer_id, number_id, contact_id, lead_id, channel, purpose, kind, actor, body_norm, is_template, idempotency_key, reserved_at)
  values (p_dealer_id, p_number_id, p_contact_id, p_lead_id, p_channel, p_purpose, p_kind, p_actor, v_norm, p_is_template, p_idempotency_key, p_now)
  returning id into v_res;
  v_next := p_now + make_interval(secs => (n.throttle_ms + floor(random() * (n.jitter_max_ms + 1))) / 1000.0);
  update salesos_ai.channel_numbers set next_allowed_at = v_next where id = p_number_id;
  return salesos_ai._decision('allow','reserved','Slot reserved.', null, v_res, jsonb_build_object('next_allowed_at', v_next, 'cap', v_cap, 'used', coalesce(v_used,0) + 1));
end $$;

-- the dispatcher refuses system emails (confirmations) to a suppressed address too
create or replace function salesos_ai.get_send_target(p_number_id uuid, p_contact_id uuid, p_now timestamptz default now())
returns jsonb language sql stable security definer set search_path = salesos_ai, pg_temp as $$
  select jsonb_build_object(
    'dealer_id', d.id, 'dealer_name', d.name, 'postal_address', d.postal_address, 'main_phone', d.main_phone,
    'number', jsonb_build_object('id', n.id, 'channel', n.channel, 'provider', n.provider, 'address', n.address, 'status', n.status, 'config', n.provider_config),
    'contact', jsonb_build_object('id', c.id, 'first_name', c.first_name, 'phone_e164', c.phone_e164, 'email', c.email),
    'whatsapp_window_open', exists (select 1 from salesos_ai.messages m where m.contact_id = c.id and m.channel = 'whatsapp' and m.direction = 'inbound'
                                      and m.created_at > p_now - interval '24 hours'),
    'email_suppressed', n.channel = 'email' and salesos_ai.is_email_suppressed(d.id, c.email))
    from salesos_ai.channel_numbers n join salesos_ai.dealers d on d.id = n.dealer_id
    join salesos_ai.contacts c on c.id = p_contact_id and c.dealer_id = n.dealer_id
   where n.id = p_number_id
$$;

-- routing never picks a suppressed mailbox (the follow-up falls through to SMS/WhatsApp when the contact has them)
create or replace function salesos_ai.pick_send_route(p_dealer_id uuid, p_contact_id uuid, p_preferred salesos_ai.channel_kind default null)
returns table (channel salesos_ai.channel_kind, number_id uuid) language sql stable security definer set search_path = salesos_ai, pg_temp as $$
  with c as (select * from salesos_ai.contacts where id = p_contact_id and dealer_id = p_dealer_id),
  last_in as (select m.channel from salesos_ai.messages m where m.contact_id = p_contact_id and m.direction = 'inbound' order by m.created_at desc limit 1),
  opts as (
    select ch, ord from (values (p_preferred, 1), ((select channel from last_in), 2), ('sms'::salesos_ai.channel_kind, 3), ('whatsapp'::salesos_ai.channel_kind, 4), ('email'::salesos_ai.channel_kind, 5)) v(ch, ord)
     where ch is not null)
  select o.ch, n.id
    from opts o cross join c
    join lateral (select id from salesos_ai.channel_numbers n where n.dealer_id = p_dealer_id and n.channel = o.ch and n.status = 'active'
                   order by n.activated_at nulls last limit 1) n on true
   where ((o.ch in ('sms','whatsapp') and coalesce(c.phone_e164, '') <> '') or (o.ch = 'email' and coalesce(c.email, '') <> '' and not salesos_ai.is_email_suppressed(p_dealer_id, c.email)))
     and not exists (select 1 from salesos_ai.contact_dnc x where x.contact_id = p_contact_id and x.cleared_at is null and (x.channel is null or x.channel = o.ch))
   order by o.ord limit 1
$$;

-- =====================================================================================
-- PART U. WHATSAPP TEMPLATE COMPLIANCE: marketing templates must carry opt-out wording
-- =====================================================================================
alter table salesos_ai.message_templates add column if not exists has_opt_out_button boolean not null default false;   -- a quick-reply button such as "Stop promotions"
alter table salesos_ai.message_templates add column if not exists compliance_status text not null default 'unchecked';
alter table salesos_ai.message_templates add column if not exists compliance_flags text[] not null default '{}';
alter table salesos_ai.message_templates add column if not exists compliance_checked_at timestamptz;
alter table salesos_ai.message_templates add column if not exists compliance_override_by uuid;
alter table salesos_ai.message_templates add column if not exists compliance_override_note text;
do $$ begin
  alter table salesos_ai.message_templates add constraint message_templates_compliance_ck check (compliance_status in ('unchecked','ok','flagged','overridden'));
exception when duplicate_object then null; end $$;

-- the rule, in one place: flags for a (category, body, button) triple. Empty array = compliant.
create or replace function salesos_ai.template_compliance_flags(p_category text, p_body text, p_has_button boolean default false)
returns text[] language sql immutable as $$
  select array_remove(array[
    case when coalesce(btrim(p_body), '') = '' then 'empty_body' end,
    case when upper(coalesce(p_category, '')) = 'MARKETING' and not coalesce(p_has_button, false)
              and coalesce(p_body, '') !~* '(\m(reply|text|send|type)\s+"?(stop|unsubscribe|end|cancel|quit)\M|\mstop\s+to\s+(opt[\s-]?out|unsubscribe|end|cancel|quit|stop)|opt[\s-]?out|\munsubscribe\M)'
         then 'missing_opt_out' end,
    case when upper(coalesce(p_category, '')) not in ('MARKETING','UTILITY','AUTHENTICATION') then 'unknown_category' end
  ], null)
$$;

create or replace function salesos_ai.message_templates_compliance() returns trigger language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare v_flags text[];
begin
  v_flags := salesos_ai.template_compliance_flags(new.category, new.body_text, new.has_opt_out_button);
  if tg_op = 'UPDATE' and old.body_text is not distinct from new.body_text and old.category is not distinct from new.category and old.has_opt_out_button = new.has_opt_out_button
     and ((old.compliance_status = 'overridden' and new.compliance_status = 'overridden')
          or (new.compliance_status = 'overridden' and new.compliance_override_by is not null and old.compliance_override_by is distinct from new.compliance_override_by)) then
    new.compliance_status := case when cardinality(v_flags) = 0 then 'ok' else 'overridden' end; new.compliance_flags := v_flags;   -- a manager's override survives status pushes, not edits
  else
    new.compliance_status := case when cardinality(v_flags) = 0 then 'ok' else 'flagged' end;
    new.compliance_flags := v_flags; new.compliance_override_by := null; new.compliance_override_note := null;
  end if;
  new.compliance_checked_at := now();
  return new;
end $$;
drop trigger if exists message_templates_compliance_trg on salesos_ai.message_templates;
create trigger message_templates_compliance_trg before insert or update on salesos_ai.message_templates for each row execute function salesos_ai.message_templates_compliance();

-- tell the desk once per flagged template
create or replace function salesos_ai.message_templates_flag_inbox() returns trigger language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
begin
  if new.compliance_status = 'flagged' and (tg_op = 'INSERT' or old.compliance_status is distinct from 'flagged')
     and not exists (select 1 from salesos_ai.agent_inbox_items i where i.kind = 'needs_review' and i.status = 'open' and i.payload->>'template_id' = new.id::text) then
    insert into salesos_ai.agent_inbox_items (dealer_id, lead_id, kind, priority, title, summary, payload)
    values (new.dealer_id, null, 'needs_review', 2, format('WhatsApp template "%s" is blocked for marketing', new.name),
            format('Flags: %s. Add opt-out wording (e.g. "Reply STOP to opt out") or an opt-out button in Meta, then it re-checks on the next sync.', array_to_string(new.compliance_flags, ', ')),
            jsonb_build_object('template_id', new.id, 'name', new.name, 'flags', new.compliance_flags));
  end if;
  return null;
end $$;
drop trigger if exists message_templates_flag_inbox_trg on salesos_ai.message_templates;
create trigger message_templates_flag_inbox_trg after insert or update on salesos_ai.message_templates for each row execute function salesos_ai.message_templates_flag_inbox();

-- the sync carries the opt-out button flag now (re-declared with the new column)
create or replace function salesos_ai.upsert_message_templates(p_number_id uuid, p_templates jsonb, p_now timestamptz default now())
returns int language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare v_dealer uuid; v_n int;
begin
  select dealer_id into v_dealer from salesos_ai.channel_numbers where id = p_number_id and provider = 'meta_cloud';
  if v_dealer is null then raise exception 'not a meta_cloud number: %', p_number_id; end if;
  insert into salesos_ai.message_templates as t (dealer_id, number_id, provider_template_id, name, language, category, status, body_text, param_count, rejected_reason, has_opt_out_button, last_synced_at, updated_at)
  select v_dealer, p_number_id, x->>'id', x->>'name', x->>'language', upper(x->>'category'), upper(x->>'status'), x->>'body_text',
         coalesce((x->>'param_count')::int, 0), nullif(nullif(x->>'rejected_reason', ''), 'NONE'), coalesce((x->>'has_opt_out_button')::boolean, false), p_now, p_now
    from jsonb_array_elements(coalesce(p_templates, '[]'::jsonb)) x
  on conflict (dealer_id, name, language) do update
     set provider_template_id = excluded.provider_template_id, category = excluded.category, status = excluded.status,
         body_text = excluded.body_text, param_count = excluded.param_count, rejected_reason = excluded.rejected_reason,
         has_opt_out_button = excluded.has_opt_out_button, number_id = excluded.number_id, last_synced_at = p_now, updated_at = p_now;
  get diagnostics v_n = row_count;
  update salesos_ai.message_templates set status = 'DELETED', updated_at = p_now
   where dealer_id = v_dealer and number_id = p_number_id and status <> 'DELETED'
     and (name, language) not in (select x->>'name', x->>'language' from jsonb_array_elements(coalesce(p_templates, '[]'::jsonb)) x);
  return v_n;
end $$;

-- a manager may accept a flagged template (e.g. the opt-out sits in a footer Meta does not return); the reason is kept
create or replace function salesos_ai.override_template_compliance(p_template_id uuid, p_note text, p_actor uuid default null)
returns text language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare t salesos_ai.message_templates; v_actor uuid;
begin
  select * into t from salesos_ai.message_templates where id = p_template_id;
  if t.id is null then raise exception 'template not found' using errcode = 'P0002'; end if;
  v_actor := salesos_ai.require_staff(t.dealer_id, p_actor, array['owner','admin','manager']);
  if length(btrim(coalesce(p_note, ''))) < 10 then raise exception 'a reason of at least 10 characters is required' using errcode = '22023'; end if;
  if t.compliance_status = 'ok' then return 'ok'; end if;
  update salesos_ai.message_templates set compliance_status = 'overridden', compliance_override_by = v_actor, compliance_override_note = left(p_note, 300) where id = t.id;
  update salesos_ai.agent_inbox_items set status = 'resolved', resolved_at = now(), resolved_by = v_actor where kind = 'needs_review' and status = 'open' and payload->>'template_id' = t.id::text;
  return 'overridden';
end $$;

-- selection: marketing purposes only ever see compliant (ok / overridden) templates
create or replace function salesos_ai.pick_whatsapp_template(p_number_id uuid, p_use text, p_purpose salesos_ai.consent_purpose)
returns table (name text, language text, body_text text, param_count int) language sql stable security definer set search_path = salesos_ai, pg_temp as $$
  select t.name, t.language, t.body_text, t.param_count from salesos_ai.message_templates t
   where t.number_id = p_number_id and t.status = 'APPROVED'
     and t.category = case when p_purpose = 'marketing' then 'MARKETING' else 'UTILITY' end
     and (p_purpose <> 'marketing' or t.compliance_status in ('ok','overridden'))
     and coalesce(t.salesos_use, 'reengage') in (p_use, 'reengage')
   order by (coalesce(t.salesos_use, 'reengage') = p_use) desc, t.updated_at desc
   limit 1
$$;

-- the dispatcher's last check before a template leaves: approved, right category for the purpose, and (marketing) compliant
create or replace function salesos_ai.check_template_send(p_number_id uuid, p_name text, p_language text, p_purpose salesos_ai.consent_purpose)
returns jsonb language plpgsql stable security definer set search_path = salesos_ai, pg_temp as $$
declare t salesos_ai.message_templates;
begin
  select * into t from salesos_ai.message_templates where number_id = p_number_id and name = p_name and language = p_language;
  if t.id is null then return jsonb_build_object('allowed', false, 'code', 'template_unknown'); end if;
  if t.status <> 'APPROVED' then return jsonb_build_object('allowed', false, 'code', 'template_not_approved', 'status', t.status); end if;
  if (p_purpose = 'marketing' and t.category <> 'MARKETING') or (p_purpose <> 'marketing' and t.category = 'MARKETING') then
    return jsonb_build_object('allowed', false, 'code', 'template_category_mismatch', 'category', t.category);
  end if;
  if t.category = 'MARKETING' and t.compliance_status not in ('ok','overridden') then
    return jsonb_build_object('allowed', false, 'code', 'template_noncompliant', 'status', t.compliance_status, 'flags', to_jsonb(t.compliance_flags));
  end if;
  return jsonb_build_object('allowed', true, 'category', t.category);
end $$;

-- existing rows get checked now (the trigger only fires on writes)
update salesos_ai.message_templates set updated_at = updated_at where compliance_status = 'unchecked';

-- =====================================================================================
-- PART V. CUSTOMER FACTS FROM THE AGENT (record_customer_fact tool)
-- =====================================================================================
alter table salesos_ai.customer_facts add column if not exists supersedes_id uuid references salesos_ai.customer_facts(id) on delete set null;

-- ISO 3779 / NHTSA check digit (position 9). I, O, Q are never valid. Case-insensitive.
create or replace function salesos_ai.vin_valid(p_vin text) returns boolean language plpgsql immutable as $$
declare v text := upper(btrim(coalesce(p_vin, ''))); i int; ch text; val int; tot int := 0; check_ch text;
  weights int[] := array[8,7,6,5,4,3,2,10,0,9,8,7,6,5,4,3,2];
begin
  if v !~ '^[A-HJ-NPR-Z0-9]{17}$' then return false; end if;
  for i in 1..17 loop
    ch := substr(v, i, 1);
    val := case when ch ~ '[0-9]' then ch::int
                else (array[1,2,3,4,5,6,7,8, null, 1,2,3,4,5, null, 7, null, 9, 2,3,4,5,6,7,8,9])[ascii(ch) - 64] end;
    tot := tot + val * weights[i];
  end loop;
  check_ch := case when tot % 11 = 10 then 'X' else (tot % 11)::text end;
  return substr(v, 9, 1) = check_ch;
end $$;

-- Record one fact the CUSTOMER stated. Never raises for bad model input: returns {result:'rejected', code, message} so the model can correct.
--   * run -> lead is trusted (the model cannot name a lead); the quote must appear verbatim in an inbound message of that lead,
--     and that message is the recorded provenance (message_id)
--   * value validated per key (VIN checksum, ranges, enums); confidence >= 0.5
--   * newer supersedes older (history kept via superseded_at + supersedes_id); a fact from an OLDER message never replaces a newer one;
--     an AI guess never replaces what a rep, form or the DMS recorded
create or replace function salesos_ai.agent_record_fact(p_run_id uuid, p_key text, p_value jsonb, p_confidence numeric, p_quote text, p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
declare r salesos_ai.agent_runs; v jsonb; v_text text; v_msg salesos_ai.messages; v_norm_q text; cur salesos_ai.customer_facts; v_new uuid; v_cur_at timestamptz;
  rej jsonb;
begin
  select * into r from salesos_ai.agent_runs where id = p_run_id;
  if r.id is null or r.lead_id is null then raise exception 'run % not found', p_run_id; end if;
  if p_key not in ('budget_max_cents','trade_in_vin','preferred_trim','purchase_timeframe','wants_financing') then
    return jsonb_build_object('result','rejected','code','invalid_key','message','Unsupported fact. Allowed: budget_max_cents, trade_in_vin, preferred_trim, purchase_timeframe, wants_financing.');
  end if;
  if p_confidence is null or p_confidence < 0.5 or p_confidence > 1 then
    return jsonb_build_object('result','rejected','code','low_confidence','message','Only record facts you are at least 50% sure the customer stated. Ask them instead.');
  end if;
  -- value validation (the source of truth; the TS tool validates first for friendlier errors)
  begin
    case p_key
      when 'budget_max_cents' then
        if jsonb_typeof(p_value) <> 'number' or (p_value #>> '{}')::numeric <> trunc((p_value #>> '{}')::numeric) or (p_value #>> '{}')::numeric not between 100000 and 50000000 then
          return jsonb_build_object('result','rejected','code','invalid_value','message','budget_max_cents must be a whole number of cents between 100000 ($1,000) and 50000000 ($500,000).'); end if;
        v := to_jsonb((p_value #>> '{}')::bigint);
      when 'trade_in_vin' then
        v_text := upper(btrim(coalesce(p_value #>> '{}', '')));
        if jsonb_typeof(p_value) <> 'string' or not salesos_ai.vin_valid(v_text) then
          return jsonb_build_object('result','rejected','code','invalid_vin','message','That VIN failed validation (17 characters, no I/O/Q, check digit). Do not guess it: ask the customer to re-send it.'); end if;
        v := to_jsonb(v_text);
      when 'preferred_trim' then
        v_text := btrim(regexp_replace(coalesce(p_value #>> '{}', ''), '[[:cntrl:]]', ' ', 'g'));
        if jsonb_typeof(p_value) <> 'string' or length(v_text) not between 1 and 60 then
          return jsonb_build_object('result','rejected','code','invalid_value','message','preferred_trim must be 1-60 characters.'); end if;
        v := to_jsonb(v_text);
      when 'purchase_timeframe' then
        if jsonb_typeof(p_value) <> 'string' or (p_value #>> '{}') not in ('now','within_30_days','within_90_days','later') then
          return jsonb_build_object('result','rejected','code','invalid_value','message','purchase_timeframe must be now, within_30_days, within_90_days or later.'); end if;
        v := p_value;
      when 'wants_financing' then
        if jsonb_typeof(p_value) <> 'boolean' then
          return jsonb_build_object('result','rejected','code','invalid_value','message','wants_financing must be true or false.'); end if;
        v := p_value;
    end case;
  exception when others then
    return jsonb_build_object('result','rejected','code','invalid_value','message','The value has the wrong type for this fact.');
  end;
  -- provenance: the customer's own words, found in this lead's inbound messages (latest match wins)
  v_norm_q := lower(regexp_replace(btrim(coalesce(p_quote, '')), '\s+', ' ', 'g'));
  if length(v_norm_q) < 3 then
    return jsonb_build_object('result','rejected','code','quote_required','message','Give the customer''s exact words (at least 3 characters) as evidence_quote.');
  end if;
  select m.* into v_msg from salesos_ai.messages m
   where m.lead_id = r.lead_id and m.direction = 'inbound'
     and position(v_norm_q in lower(regexp_replace(m.body, '\s+', ' ', 'g'))) > 0
   order by m.created_at desc limit 1;
  if v_msg.id is null then
    return jsonb_build_object('result','rejected','code','quote_not_found','message','That quote is not in the customer''s messages. Only record what the customer actually wrote, quoted verbatim.');
  end if;
  select * into cur from salesos_ai.customer_facts where lead_id = r.lead_id and fact_key = p_key and superseded_at is null for update;
  if cur.id is not null then
    if cur.value = v then return jsonb_build_object('result','unchanged','fact_id',cur.id); end if;
    if salesos_ai.fact_source_rank('ai_extracted') < salesos_ai.fact_source_rank(cur.source) then
      return jsonb_build_object('result','kept_existing','fact_id',cur.id,'message','A team member or the form already recorded this; do not change it.');
    end if;
    select coalesce((select mm.created_at from salesos_ai.messages mm where mm.id = cur.message_id), cur.created_at) into v_cur_at;
    if v_msg.created_at < v_cur_at then
      return jsonb_build_object('result','stale','fact_id',cur.id,'message','A newer message already set this fact; the older statement does not replace it.');
    end if;
    update salesos_ai.customer_facts set superseded_at = p_now where id = cur.id;
  end if;
  insert into salesos_ai.customer_facts (dealer_id, lead_id, fact_key, value, source, confidence, evidence_quote, message_id, run_id, supersedes_id, created_at)
  values (r.dealer_id, r.lead_id, p_key, v, 'ai_extracted', p_confidence, left(btrim(p_quote), 300), v_msg.id, r.id, cur.id, p_now) returning id into v_new;
  return jsonb_build_object('result', case when cur.id is null then 'inserted' else 'superseded' end, 'fact_id', v_new, 'message_id', v_msg.id, 'superseded_id', cur.id);
end $$;

-- =====================================================================================
-- PART W. STAFF PHONE VERIFICATION (a code texted to the number; only a verified identity can text the CRM)
-- =====================================================================================
create table if not exists salesos_ai.staff_verifications (
  id uuid primary key default gen_random_uuid(),
  dealer_id uuid not null references salesos_ai.dealers(id) on delete cascade,
  staff_identity_id uuid not null references salesos_ai.staff_identities(id) on delete cascade,
  code_hash text not null,                                    -- sha256(code:identity:salt); the code itself is never stored
  salt text not null,
  attempts int not null default 0,
  max_attempts int not null default 5,
  created_by uuid,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  sent_at timestamptz,
  send_error text,
  superseded_at timestamptz,
  consumed_at timestamptz
);
create index if not exists staff_verifications_identity_idx on salesos_ai.staff_verifications (staff_identity_id, created_at desc);

-- A client (authenticated/anon) can never mark an identity active or verified, nor keep it active after changing the number it trusts.
create or replace function salesos_ai.staff_identities_guard() returns trigger language plpgsql as $$
begin
  if current_user not in ('authenticated','anon') then return new; end if;     -- definer functions / service role
  if tg_op = 'INSERT' then
    if new.status = 'active' or new.verified_at is not null then raise exception 'staff identities start pending and are verified by a texted code' using errcode = '42501'; end if;
    return new;
  end if;
  if (new.status = 'active' and old.status <> 'active') or new.verified_at is distinct from old.verified_at then
    raise exception 'only the verification code flow can activate a staff identity' using errcode = '42501';
  end if;
  if old.status = 'active' and (new.address is distinct from old.address or new.channel is distinct from old.channel or new.user_id is distinct from old.user_id) then
    new.status := 'pending'; new.verified_at := null;           -- a changed number has to be verified again
  end if;
  return new;
end $$;
drop trigger if exists staff_identities_guard_trg on salesos_ai.staff_identities;
create trigger staff_identities_guard_trg before insert or update on salesos_ai.staff_identities for each row execute function salesos_ai.staff_identities_guard();

-- Start: the identity's own user, or an owner/admin, requests a code. Returns the PLAINTEXT code once, to the service role,
-- which texts it through the channel adapter. Limits: 60 s between codes (unless the last send failed), 3 per hour; a new code retires the old.
create or replace function salesos_ai.start_staff_verification(p_identity_id uuid, p_actor uuid default null, p_now timestamptz default now(), p_ttl interval default interval '10 minutes')
returns table (verification_id uuid, dealer_id uuid, code text, expires_at timestamptz, to_address text, channel salesos_ai.channel_kind, number_id uuid, number_address text, provider text, number_config jsonb, dealer_name text)
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
#variable_conflict use_column
declare si salesos_ai.staff_identities; v_actor uuid := coalesce(auth.uid(), p_actor); v_code text; v_salt text; v_id uuid; v_last salesos_ai.staff_verifications; v_recent int; n salesos_ai.channel_numbers;
begin
  select * into si from salesos_ai.staff_identities where id = p_identity_id;
  if si.id is null then raise exception 'not_found: staff identity' using errcode = 'P0002'; end if;
  if v_actor is null then raise exception 'actor required' using errcode = '42501'; end if;
  if v_actor <> si.user_id then perform salesos_ai.require_staff(si.dealer_id, v_actor, array['owner','admin']); end if;
  if not exists (select 1 from salesos_ai.dealer_members m where m.user_id = si.user_id and m.dealer_id = si.dealer_id) then raise exception 'not a member of this dealer' using errcode = '42501'; end if;
  if si.status = 'revoked' then raise exception 'identity revoked' using errcode = '22023'; end if;
  if si.status = 'active' then raise exception 'already verified' using errcode = '22023'; end if;
  if si.channel not in ('sms','whatsapp') then raise exception 'unsupported_channel: staff verification is by SMS or WhatsApp' using errcode = '22023'; end if;
  select * into n from salesos_ai.channel_numbers c where c.dealer_id = si.dealer_id and c.channel = si.channel and c.status = 'active' order by c.activated_at nulls last limit 1;
  if n.id is null then raise exception 'no_sending_number: no active % number for this dealer', si.channel using errcode = '22023'; end if;
  select count(*) into v_recent from salesos_ai.staff_verifications sv where sv.staff_identity_id = si.id and sv.created_at > p_now - interval '1 hour';
  if v_recent >= 3 then raise exception 'rate_limited: too many codes requested; try again later' using errcode = '54000'; end if;
  select * into v_last from salesos_ai.staff_verifications sv where sv.staff_identity_id = si.id order by sv.created_at desc limit 1;
  if v_last.id is not null and v_last.created_at > p_now - interval '60 seconds' and v_last.send_error is null then
    raise exception 'cooldown: wait a minute before requesting another code' using errcode = '54000';
  end if;
  update salesos_ai.staff_verifications set superseded_at = p_now where staff_identity_id = si.id and consumed_at is null and superseded_at is null;
  -- gen_random_uuid() is CSPRNG-backed; 32 bits mod 10^6 has negligible bias for a 10-minute, 5-attempt code
  v_code := lpad(((('x' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))::bit(32)::bigint) % 1000000)::text, 6, '0');
  v_salt := replace(gen_random_uuid()::text, '-', '');
  insert into salesos_ai.staff_verifications (dealer_id, staff_identity_id, code_hash, salt, created_by, created_at, expires_at)
  values (si.dealer_id, si.id, encode(sha256(convert_to(v_code || ':' || si.id::text || ':' || v_salt, 'UTF8')), 'hex'), v_salt, v_actor, p_now, p_now + p_ttl) returning id into v_id;
  verification_id := v_id; dealer_id := si.dealer_id; code := v_code; expires_at := p_now + p_ttl; to_address := si.address; channel := si.channel;
  number_id := n.id; number_address := n.address; provider := n.provider; number_config := n.provider_config;
  select d.name into dealer_name from salesos_ai.dealers d where d.id = si.dealer_id;
  return next;
end $$;

create or replace function salesos_ai.mark_staff_verification_sent(p_verification_id uuid, p_ok boolean, p_error text default null, p_now timestamptz default now())
returns void language sql security definer set search_path = salesos_ai, pg_temp as $$
  update salesos_ai.staff_verifications set sent_at = case when p_ok then p_now end, send_error = case when p_ok then null else left(coalesce(p_error, 'send_failed'), 120) end
   where id = p_verification_id
$$;

-- Confirm: only the identity's OWN user (proof of possession; an admin cannot confirm on someone's behalf).
-- Returns a result instead of raising so the attempt counter persists. Results: verified | wrong_code | expired | locked | no_pending
create or replace function salesos_ai.confirm_staff_verification(p_identity_id uuid, p_code text, p_actor uuid default null, p_now timestamptz default now())
returns table (result text, attempts_left int)
language plpgsql security definer set search_path = salesos_ai, pg_temp as $$
#variable_conflict use_column
declare si salesos_ai.staff_identities; v_actor uuid := coalesce(auth.uid(), p_actor); sv salesos_ai.staff_verifications; v_hash text;
begin
  select * into si from salesos_ai.staff_identities where id = p_identity_id;
  if si.id is null then raise exception 'not_found: staff identity' using errcode = 'P0002'; end if;
  if v_actor is null or v_actor <> si.user_id then raise exception 'forbidden: only the person being verified can enter the code' using errcode = '42501'; end if;
  if si.status = 'revoked' then raise exception 'identity revoked' using errcode = '22023'; end if;
  if si.status = 'active' then result := 'verified'; attempts_left := 0; return next; return; end if;
  select * into sv from salesos_ai.staff_verifications x where x.staff_identity_id = si.id and x.consumed_at is null and x.superseded_at is null order by x.created_at desc limit 1 for update;
  if sv.id is null then result := 'no_pending'; attempts_left := 0; return next; return; end if;
  if sv.expires_at <= p_now then result := 'expired'; attempts_left := 0; return next; return; end if;
  if sv.attempts >= sv.max_attempts then result := 'locked'; attempts_left := 0; return next; return; end if;
  update salesos_ai.staff_verifications set attempts = attempts + 1 where id = sv.id;
  v_hash := encode(sha256(convert_to(btrim(coalesce(p_code, '')) || ':' || si.id::text || ':' || sv.salt, 'UTF8')), 'hex');
  if v_hash = sv.code_hash then
    update salesos_ai.staff_verifications set consumed_at = p_now where id = sv.id;
    update salesos_ai.staff_identities set status = 'active', verified_at = p_now where id = si.id;
    result := 'verified'; attempts_left := 0; return next; return;
  end if;
  attempts_left := sv.max_attempts - (sv.attempts + 1);
  result := case when attempts_left <= 0 then 'locked' else 'wrong_code' end;
  return next;
end $$;

-- =====================================================================================
-- PART X. schedule, retention, RLS, grants
-- =====================================================================================
create or replace function salesos_ai.prune_runtime(p_now timestamptz default now())
returns void language sql security definer set search_path = salesos_ai, pg_temp as $$
  delete from salesos_ai.event_log where received_at < p_now - interval '30 days';
  delete from salesos_ai.agent_jobs where status in ('done','skipped','escalated','dead') and updated_at < p_now - interval '30 days';
  delete from salesos_ai.send_attempts where status in ('sent','failed') and started_at < p_now - interval '45 days';
  delete from salesos_ai.prequal_links where expires_at < p_now - interval '30 days';
  delete from salesos_ai.staff_verifications where created_at < p_now - interval '30 days';
  delete from salesos_ai.keyword_replies where status in ('sent','gave_up','carrier_blocked','expired','unknown') and coalesce(finished_at, created_at) < p_now - interval '180 days';
$$;

do $cron$
begin
  if to_regclass('cron.job') is null then raise notice 'pg_cron not available; phase-5 schedule skipped'; return; end if;
  perform cron.schedule('salesos-keyword-replies', '15 seconds', $$select salesos_ai.kick_keyword_reply_worker()$$);
exception when others then
  raise notice 'pg_cron scheduling skipped: %', sqlerrm;
end
$cron$;

do $rls$
declare t text;
begin
  foreach t in array array['email_bounce_events','email_suppressions'] loop
    execute format('alter table salesos_ai.%I enable row level security', t);
    execute format('drop policy if exists %I on salesos_ai.%I', t || '_member_select', t);
    execute format('create policy %I on salesos_ai.%I for select to authenticated using (salesos_ai.is_dealer_member(dealer_id))', t || '_member_select', t);
    execute format('revoke all on salesos_ai.%I from anon, authenticated', t);
    execute format('grant select on salesos_ai.%I to authenticated', t);
  end loop;
  alter table salesos_ai.staff_verifications enable row level security;
  revoke all on salesos_ai.staff_verifications from anon, authenticated;
end
$rls$;

do $grants$
declare r record;
begin
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'salesos_ai' and p.proname = any (array[
              'begin_keyword_reply','claim_keyword_replies','finish_keyword_reply','kick_keyword_reply_worker','record_email_bounce',
              'is_email_suppressed','check_template_send','agent_record_fact','start_staff_verification','mark_staff_verification_sent',
              'confirm_staff_verification','upsert_message_templates','pick_whatsapp_template','get_send_target','pick_send_route','can_send','prune_runtime'])
  loop
    execute format('revoke all on function %s from public, anon, authenticated', r.sig);
    execute format('grant execute on function %s to service_role', r.sig);
  end loop;
  -- staff-facing: the function re-checks the caller's role (require_staff)
  for r in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'salesos_ai' and p.proname = any (array['suppress_email','clear_email_suppression','override_template_compliance'])
  loop
    execute format('revoke all on function %s from public, anon', r.sig);
    execute format('grant execute on function %s to authenticated, service_role', r.sig);
  end loop;
end
$grants$;
