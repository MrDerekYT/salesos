\set ON_ERROR_STOP 1
-- dealers/users
insert into dealers(id,name,timezone) values
 ('00000000-0000-0000-0000-0000000001a1','NY Motors','America/New_York'),
 ('00000000-0000-0000-0000-0000000001a2','LA Motors','America/Los_Angeles');
insert into dealer_members(user_id,dealer_id,role) values
 ('00000000-0000-0000-0000-0000000001b1','00000000-0000-0000-0000-0000000001a1','sales'),
 ('00000000-0000-0000-0000-0000000001b2','00000000-0000-0000-0000-0000000001a1','manager'),
 ('00000000-0000-0000-0000-0000000001b3','00000000-0000-0000-0000-0000000001a2','sales'),
 ('00000000-0000-0000-0000-0000000001b4','00000000-0000-0000-0000-0000000001a1','viewer');
\set ny '\'00000000-0000-0000-0000-0000000001a1\'::uuid'
\set la '\'00000000-0000-0000-0000-0000000001a2\'::uuid'
\set u1 '\'00000000-0000-0000-0000-0000000001b1\'::uuid'
\set u2 '\'00000000-0000-0000-0000-0000000001b2\'::uuid'
\set u3 '\'00000000-0000-0000-0000-0000000001b3\'::uuid'

-- enqueue by store timezone. 2026-03-10 is a Tuesday and EDT/PDT are in effect.
select t.eq('11:00Z = 07:00 EDT / 04:00 PDT -> only NY (sales, manager) enqueued', enqueue_due_briefings('2026-03-10 11:00:00+00'), 2);
select t.eq('re-running the tick is idempotent', enqueue_due_briefings('2026-03-10 11:15:00+00'), 0);
select t.eq('13:30Z = 09:30 EDT (past the 3h window) / 06:30 PDT -> only LA', enqueue_due_briefings('2026-03-10 13:30:00+00'), 1);
select t.eq('viewer never gets a briefing', (select count(*) from daily_briefings where user_id='00000000-0000-0000-0000-0000000001b4')::int, 0);
select t.eq('local_date is the dealer-local date', (select local_date from daily_briefings where user_id=:u3), '2026-03-10'::date);
select t.eq('Sunday (briefing_days excludes 7) -> nobody', enqueue_due_briefings('2026-03-15 12:00:00+00'), 0);
select t.eq('DST: Mar 9 11:00Z is 07:00 EDT -> NY again next day', enqueue_due_briefings('2026-03-11 11:00:00+00'), 2);

-- claim: pending -> building, once; stale building is reclaimable
do $$ declare n int; begin
  select count(*) into n from claim_pending_briefings(100, '2026-03-11 11:05:00+00');
  perform t.eq('claim all pending', n, 5);
  select count(*) into n from claim_pending_briefings(100, '2026-03-11 11:06:00+00');
  perform t.eq('no double-claim', n, 0);
  select count(*) into n from claim_pending_briefings(100, '2026-03-11 11:30:00+00');
  perform t.eq('stale building claims are retried (attempt 2)', n, 5);
  perform t.eq('attempts counted', (select max(attempts) from daily_briefings)::int, 2);
end $$;

-- scoring math
select t.ok('waiting 1h: ramp .7 * value .5', abs((select score from briefing_score('waiting_reply', now() - interval '1 hour', null, true)) - 0.35) < 0.002);
select t.ok('waiting 3h: ramp saturated -> .5', abs((select score from briefing_score('waiting_reply', now() - interval '3 hours', null, true)) - 0.5) < 0.002);
select t.ok('waiting 100h decays to .5*.5^((100-24)/48)', abs((select score from briefing_score('waiting_reply', now() - interval '100 hours', null, true)) - 0.5 * power(0.5, 76.0/48)) < 0.002);
select t.ok('bigger deal scores higher', (select score from briefing_score('waiting_reply', now() - interval '3 hours', 5000000, true)) > (select score from briefing_score('waiting_reply', now() - interval '3 hours', 100000, true)));
select t.ok('unreachable contact ranks lower (x0.6)', abs((select score from briefing_score('waiting_reply', now() - interval '3 hours', null, false)) - 0.3) < 0.002);
select t.ok('lease ending: urgency climbs as the date nears', (select score from briefing_score('lease_ending', current_date - 5, null, true)) < (select score from briefing_score('lease_ending', current_date - 80, null, true)));

-- fixtures relative to real now() (views use now())
insert into contacts(id,dealer_id,first_name,phone_e164) select ('00000000-0000-0000-0000-00000001c0'||lpad(g::text,2,'0'))::uuid, :ny, 'N'||g, '+1555556'||(1000+g) from generate_series(1,9) g;
insert into contacts(id,dealer_id,first_name,phone_e164) values ('00000000-0000-0000-0000-00000001c0aa', :la, 'LA1', '+15555569999');
insert into vehicles(id,dealer_id,vin,year,make,model,price_cents,status) values
 ('00000000-0000-0000-0000-00000001d001', :ny, '1HGCM82633A000001', 2024,'Honda','Accord',3000000,'available');
insert into leads(id,dealer_id,contact_id,assigned_to,stage,value_cents) values
 ('00000000-0000-0000-0000-00000001e001', :ny,'00000000-0000-0000-0000-00000001c001', :u1,'qualifying', 4000000),   -- A waiting + callback
 ('00000000-0000-0000-0000-00000001e002', :ny,'00000000-0000-0000-0000-00000001c002', :u1,'test_drive', 2500000),   -- B test drive today
 ('00000000-0000-0000-0000-00000001e003', :ny,'00000000-0000-0000-0000-00000001c003', :u1,'negotiating', 3500000),  -- C hot gone quiet
 ('00000000-0000-0000-0000-00000001e004', :ny,'00000000-0000-0000-0000-00000001c004', null,'qualifying', 1500000),  -- E unassigned trade-in
 ('00000000-0000-0000-0000-00000001e005', :ny,'00000000-0000-0000-0000-00000001c005', :u1,'qualifying', 2000000),   -- F price drop, all-channel DNC
 ('00000000-0000-0000-0000-00000001e006', :ny,'00000000-0000-0000-0000-00000001c006', :u1,'lost', 9000000),        -- H closed: excluded
 ('00000000-0000-0000-0000-00000001e0aa', :la,'00000000-0000-0000-0000-00000001c0aa', :u3,'qualifying', 9900000);  -- other tenant
-- A: inbound 3h ago (through the trigger) + a promised callback due 1h ago
insert into messages(dealer_id,lead_id,contact_id,channel,direction,body,created_at) values (:ny,'00000000-0000-0000-0000-00000001e001','00000000-0000-0000-0000-00000001c001','sms','inbound','price on the Accord?', now() - interval '3 hours');
insert into followups(dealer_id,lead_id,kind,due_at,reason) values (:ny,'00000000-0000-0000-0000-00000001e001','agent_promise', now() - interval '1 hour','check trade value');
-- B: visit a minute from now
insert into appointments(dealer_id,lead_id,vehicle_id,kind,starts_at,status) values (:ny,'00000000-0000-0000-0000-00000001e002','00000000-0000-0000-0000-00000001d001','test_drive', now() + interval '1 minute','confirmed');
-- C: silent 4-5 days
update leads set last_inbound_at = now() - interval '5 days', last_outbound_at = now() - interval '4 days' where id = '00000000-0000-0000-0000-00000001e003';
-- E: trade-in waiting 6h
insert into trade_in_appraisals(dealer_id,lead_id,make,model,status,requested_at) values (:ny,'00000000-0000-0000-0000-00000001e004','Toyota','Camry','requested', now() - interval '6 hours');
-- F: price drop on a viewed vehicle; contact is all-channel DNC
insert into lead_vehicle_views(dealer_id,lead_id,vehicle_id,viewed_at) values (:ny,'00000000-0000-0000-0000-00000001e005','00000000-0000-0000-0000-00000001d001', now() - interval '2 days');
insert into vehicle_price_events(dealer_id,vehicle_id,old_price_cents,new_price_cents,changed_at) values (:ny,'00000000-0000-0000-0000-00000001d001',3200000,3000000, now() - interval '3 hours');
insert into consent_events(dealer_id,contact_id,channel,purpose,action,source) values (:ny,'00000000-0000-0000-0000-00000001c005',null,null,'revoke','staff_entry');
-- H: closed lead with a waiting inbound
insert into messages(dealer_id,lead_id,contact_id,channel,direction,body,created_at) values (:ny,'00000000-0000-0000-0000-00000001e006','00000000-0000-0000-0000-00000001c006','sms','inbound','hello', now() - interval '5 hours');
-- LA waiting
insert into messages(dealer_id,lead_id,contact_id,channel,direction,body,created_at) values (:la,'00000000-0000-0000-0000-00000001e0aa','00000000-0000-0000-0000-00000001c0aa','sms','inbound','hi', now() - interval '5 hours');

select t.eq('each candidate view contributes', (select count(distinct kind) from briefing_candidates where dealer_id = :ny)::int, 6);   -- waiting, today, hot, callback, trade, price (no noshow/lease)

do $$ declare b uuid; n int; r record; begin
  select id into b from daily_briefings where user_id = '00000000-0000-0000-0000-0000000001b1' and local_date = '2026-03-10';
  n := build_briefing_items(b);
  perform t.eq('rep u1: A, B, C, F (E is unassigned, H closed, LA is another tenant)', n, 4);
  perform t.eq('ranking: waiting > test drive today > hot quiet > price drop',
    (select string_agg(kind::text, ' > ' order by rank) from briefing_items where briefing_id = b),
    'waiting_reply > test_drive_today > hot_gone_quiet > price_drop_viewed');
  perform t.eq('A dedupes callback into also_kinds', (select evidence->'also_kinds' from briefing_items where briefing_id=b and rank=1), '["callback_due"]'::jsonb);
  perform t.eq('F flagged unreachable (DNC)', (select (evidence->>'contact_reachable')::boolean from briefing_items where briefing_id=b and kind='price_drop_viewed'), false);
  perform t.ok('deterministic reason text exists', (select bool_and(length(reason_text) > 10) from briefing_items where briefing_id=b));
  perform t.eq('facts frozen: counts only', (select facts->>'total_candidates' from daily_briefings where id=b), '5');   -- A(wait)+A(callback)+B+C+F
  perform t.ok('facts contain no PII keys', (select not (facts::text ~* 'name|phone|body')  from daily_briefings where id=b));
  perform t.eq('rebuild is idempotent', build_briefing_items(b), 4);
  perform t.eq('rank unique & dense', (select array_agg(rank order by rank) from briefing_items where briefing_id=b), array[1,2,3,4]);

  select id into b from daily_briefings where user_id = '00000000-0000-0000-0000-0000000001b2' and local_date = '2026-03-10';
  perform build_briefing_items(b);
  perform t.eq('manager also sees the unassigned trade-in', (select count(*) from briefing_items where briefing_id=b and kind='trade_in_pending')::int, 1);

  update dealer_settings set briefing_size = 2 where dealer_id = '00000000-0000-0000-0000-0000000001a1';
  select id into b from daily_briefings where user_id = '00000000-0000-0000-0000-0000000001b1' and local_date = '2026-03-10';
  perform t.eq('briefing_size caps the list', build_briefing_items(b), 2);

  select id into b from daily_briefings where user_id = '00000000-0000-0000-0000-0000000001b3' and local_date = '2026-03-10';
  perform t.eq('LA rep sees only LA', build_briefing_items(b), 1);
  update daily_briefings set status='delivered' where id = b;
  perform t.eq('delivered briefings are never rebuilt', build_briefing_items(b), 0);
  perform t.eq('manager rollup', (select items_total from v_briefing_manager_rollup where user_id='00000000-0000-0000-0000-0000000001b3')::int, 1);
end $$;
\echo BRIEFING TESTS PASSED
