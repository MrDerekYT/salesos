\set ON_ERROR_STOP 1
-- two dealers, two users; user X is a sales rep at dealer 1 only
insert into dealers(id,name) values ('00000000-0000-0000-0000-0000000002a1','RLS One'),('00000000-0000-0000-0000-0000000002a2','RLS Two');
insert into dealer_members(user_id,dealer_id,role) values
 ('00000000-0000-0000-0000-0000000002b1','00000000-0000-0000-0000-0000000002a1','sales'),
 ('00000000-0000-0000-0000-0000000002b2','00000000-0000-0000-0000-0000000002a1','manager'),
 ('00000000-0000-0000-0000-0000000002b3','00000000-0000-0000-0000-0000000002a2','owner');
insert into contacts(id,dealer_id,first_name,phone_e164) values
 ('00000000-0000-0000-0000-0000000002c1','00000000-0000-0000-0000-0000000002a1','One','+15555558001'),
 ('00000000-0000-0000-0000-0000000002c2','00000000-0000-0000-0000-0000000002a2','Two','+15555558002');
insert into consent_events(dealer_id,contact_id,channel,purpose,action,source,disclosure_text_version) values
 ('00000000-0000-0000-0000-0000000002a1','00000000-0000-0000-0000-0000000002c1','sms','marketing','grant','web_form','v1'),
 ('00000000-0000-0000-0000-0000000002a2','00000000-0000-0000-0000-0000000002c2','sms','marketing','grant','web_form','v1');
insert into daily_briefings(id,dealer_id,user_id,local_date) values
 ('00000000-0000-0000-0000-0000000002d1','00000000-0000-0000-0000-0000000002a1','00000000-0000-0000-0000-0000000002b1','2026-03-10'),
 ('00000000-0000-0000-0000-0000000002d2','00000000-0000-0000-0000-0000000002a1','00000000-0000-0000-0000-0000000002b2','2026-03-10');

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000002b1"}', false);
set role authenticated;
select t.eq('rep sees only own dealer consent events', (select count(*) from consent_events)::int, 1);
select t.eq('rep sees own dealer contacts consent state', (select count(*) from contact_consent_state)::int, 1);
select t.eq('rep sees only their own briefing', (select count(*) from daily_briefings)::int, 1);
select t.eq('rep cannot read ai_budgets of other dealers', (select count(*) from ai_budgets where dealer_id='00000000-0000-0000-0000-0000000002a2')::int, 0);
select t.raises('rep cannot insert consent for another dealer',
  $q$insert into consent_events(dealer_id,contact_id,channel,purpose,action,source,actor_user_id) values ('00000000-0000-0000-0000-0000000002a2','00000000-0000-0000-0000-0000000002c2','sms','marketing','grant','in_person_form','00000000-0000-0000-0000-0000000002b1')$q$, '%row-level security%');
select t.raises('rep cannot self-grant via a non-staff source (web_form)',
  $q$insert into consent_events(dealer_id,contact_id,channel,purpose,action,source,actor_user_id,disclosure_text_version) values ('00000000-0000-0000-0000-0000000002a1','00000000-0000-0000-0000-0000000002c1','sms','marketing','grant','web_form','00000000-0000-0000-0000-0000000002b1','v1')$q$, '%row-level security%');
select t.raises('rep cannot call can_send directly', $q$select can_send('00000000-0000-0000-0000-0000000002a1','00000000-0000-0000-0000-0000000002c1','sms','marketing','followup',gen_random_uuid())$q$, '%permission denied%');
select t.raises('rep cannot write ai_budgets', $q$update ai_budgets set monthly_cap_cents = 999999$q$, '%permission denied%');
with u as (update dealer_settings set auto_send_enabled = true where dealer_id='00000000-0000-0000-0000-0000000002a1' returning 1) select t.eq('rep cannot update dealer_settings (RLS filters the row)', (select count(*) from u)::int, 0);
select t.raises('rep cannot touch message_text columns on drafts', $q$update outbound_drafts set body_ai = 'x'$q$, '%permission denied%');
select t.raises('rep cannot delete consent events', $q$delete from consent_events$q$, '%permission denied%');
reset role;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000002b2"}', false);
set role authenticated;
select t.eq('manager sees all dealer briefings', (select count(*) from daily_briefings)::int, 2);
reset role;

select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000002b3"}', false);
set role authenticated;
select t.eq('owner of dealer 2 sees only dealer 2 data', (select count(*) from consent_events)::int, 1);
with u as (update dealer_settings set auto_send_enabled = true where dealer_id='00000000-0000-0000-0000-0000000002a2' returning 1) select t.eq('owner can update settings', (select count(*) from u)::int, 1);
reset role;
select set_config('request.jwt.claims', '', false);

-- anonymous sees nothing
set role anon;
select t.raises('anon has no access to consent_events', $q$select * from consent_events$q$, '%permission denied%');
reset role;

-- cron
do $$ declare n int; begin
  if to_regclass('cron.job') is null then raise notice 'ok   [cron skipped: pg_cron unavailable]'; return; end if;
  select count(*) into n from cron.job where jobname in ('salesos-briefing-enqueue','salesos-briefing-process','salesos-outbound-sweep','salesos-stale-drafts','salesos-prune');
  perform t.eq('5 phase-1 pg_cron jobs scheduled', n, 5);
  perform t.eq('briefing enqueue every 15 min', (select schedule from cron.job where jobname='salesos-briefing-enqueue'), '*/15 * * * *');
end $$;
-- Edge-function kickers degrade to no-ops without pg_net/vault
select t.ok('invoke_edge_function without pg_net is a no-op', invoke_edge_function('morning-briefing') is null);
select kick_briefing_worker(), kick_outbound_sweeper();
\echo RLS_CRON TESTS PASSED
