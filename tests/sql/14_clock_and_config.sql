\set ON_ERROR_STOP 1
-- Gap fixes: injectable clock (midnight flake) + per-dealer briefing config with global fallback
insert into dealers(id,name,timezone) values
 ('00000000-0000-0000-0014-0000000000a1','Clock NY','America/New_York'),
 ('00000000-0000-0000-0014-0000000000a2','Clock Other','America/New_York');
insert into dealer_members(user_id,dealer_id,role) values
 ('00000000-0000-0000-0014-0000000000b1','00000000-0000-0000-0014-0000000000a1','sales');
insert into contacts(id,dealer_id,first_name,phone_e164) values
 ('00000000-0000-0000-0014-0000000000c1','00000000-0000-0000-0014-0000000000a1','Mia','+15555514001'),
 ('00000000-0000-0000-0014-0000000000c2','00000000-0000-0000-0014-0000000000a1','Max','+15555514002');
insert into leads(id,dealer_id,contact_id,assigned_to,stage) values
 ('00000000-0000-0000-0014-0000000000e1','00000000-0000-0000-0014-0000000000a1','00000000-0000-0000-0014-0000000000c1','00000000-0000-0000-0014-0000000000b1','test_drive'),
 ('00000000-0000-0000-0014-0000000000e2','00000000-0000-0000-0014-0000000000a1','00000000-0000-0000-0014-0000000000c2','00000000-0000-0000-0014-0000000000b1','test_drive');
-- 23:50 EDT on Mar 10 (= 03:50Z Mar 11) and 00:10 EDT on Mar 11 (= 04:10Z)
insert into appointments(dealer_id,lead_id,kind,starts_at,status) values
 ('00000000-0000-0000-0014-0000000000a1','00000000-0000-0000-0014-0000000000e1','test_drive','2026-03-11 03:50:00+00','confirmed'),
 ('00000000-0000-0000-0014-0000000000a1','00000000-0000-0000-0014-0000000000e2','test_drive','2026-03-11 04:10:00+00','confirmed');

select t.ok('app_now() defaults to now()', abs(extract(epoch from app_now() - now())) < 1);
select set_config('salesos.now', '2026-03-11 03:40:00+00', false);      -- 23:40 EDT Mar 10
select t.eq('app_now() honours the injected clock', app_now(), '2026-03-11 03:40:00+00'::timestamptz);
select t.eq('23:40 local: only the 23:50 drive is "today"', (select array_agg(lead_id::text order by lead_id) from v_cand_test_drive_today where dealer_id = '00000000-0000-0000-0014-0000000000a1'), array['00000000-0000-0000-0014-0000000000e1']);
select set_config('salesos.now', '2026-03-11 04:05:00+00', false);      -- 00:05 EDT Mar 11
select t.eq('00:05 local: the 00:10 drive is today, yesterday''s is not', (select array_agg(lead_id::text order by lead_id) from v_cand_test_drive_today where dealer_id = '00000000-0000-0000-0014-0000000000a1'), array['00000000-0000-0000-0014-0000000000e2']);
select set_config('salesos.now', '', false);
select t.eq('real clock (2026-11) sees neither', (select count(*) from v_cand_test_drive_today where dealer_id = '00000000-0000-0000-0014-0000000000a1')::int, 0);

-- build_briefing_items pins the views to its p_now and restores the session clock afterwards
insert into daily_briefings(id,dealer_id,user_id,local_date) values ('00000000-0000-0000-0014-0000000000d1','00000000-0000-0000-0014-0000000000a1','00000000-0000-0000-0014-0000000000b1','2026-03-10');
select t.eq('build at 23:40 local -> 1 item', build_briefing_items('00000000-0000-0000-0014-0000000000d1', '2026-03-11 03:40:00+00'), 1);
select t.eq('item is the 23:50 drive', (select lead_id::text from briefing_items where briefing_id = '00000000-0000-0000-0014-0000000000d1'), '00000000-0000-0000-0014-0000000000e1');
select t.eq('session clock untouched after build', coalesce(current_setting('salesos.now', true), ''), '');

-- per-dealer config with global fallback
select t.eq('global weight when no override', (select parts->>'config' from briefing_score('waiting_reply', '2026-03-10 12:00+00', null, true, '2026-03-10 15:00+00', '00000000-0000-0000-0014-0000000000a1')), 'global');
insert into dealer_briefing_kind_config(dealer_id,kind,weight) values ('00000000-0000-0000-0014-0000000000a1','waiting_reply',0.2);
select t.ok('dealer override weight 0.2 applies (3h wait, value .5 => .1)', abs((select score from briefing_score('waiting_reply', '2026-03-10 12:00+00', null, true, '2026-03-10 15:00+00', '00000000-0000-0000-0014-0000000000a1')) - 0.1) < 0.001);
select t.eq('override is labelled', (select parts->>'config' from briefing_score('waiting_reply', '2026-03-10 12:00+00', null, true, '2026-03-10 15:00+00', '00000000-0000-0000-0014-0000000000a1')), 'dealer');
select t.ok('NULL columns fall back to global (half-life 48h kept)', (select half_life_hours from briefing_kind_cfg('00000000-0000-0000-0014-0000000000a1','waiting_reply')) = 48);
select t.ok('other dealer still uses the global weight 1.0', abs((select score from briefing_score('waiting_reply', '2026-03-10 12:00+00', null, true, '2026-03-10 15:00+00', '00000000-0000-0000-0014-0000000000a2')) - 0.5) < 0.001);
insert into dealer_briefing_kind_config(dealer_id,kind,enabled) values ('00000000-0000-0000-0014-0000000000a1','test_drive_today',false);
select t.eq('disabled kind is skipped by the build', build_briefing_items('00000000-0000-0000-0014-0000000000d1', '2026-03-11 03:40:00+00'), 0);

-- RLS: managers edit their own dealer's overrides only
insert into dealer_members(user_id,dealer_id,role) values ('00000000-0000-0000-0014-0000000000b2','00000000-0000-0000-0014-0000000000a1','manager');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0014-0000000000b2"}', false);
set role authenticated;
with u as (update dealer_briefing_kind_config set weight = 0.3 where dealer_id = '00000000-0000-0000-0014-0000000000a1' and kind = 'waiting_reply' returning 1)
select t.eq('manager updates own dealer override', (select count(*) from u)::int, 1);
select t.raises('manager cannot write another dealer''s config',
  $q$insert into dealer_briefing_kind_config(dealer_id,kind,weight) values ('00000000-0000-0000-0014-0000000000a2','lease_ending',0.1)$q$, '%row-level security%');
reset role;
select set_config('request.jwt.claims', '', false);
select 'CLOCK_CONFIG TESTS PASSED';
