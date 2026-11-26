\set ON_ERROR_STOP 1
insert into dealers(id,name) values ('00000000-0000-0000-0000-0000000000f1','Agent Motors');
insert into contacts(id,dealer_id,first_name,phone_e164) values ('00000000-0000-0000-0000-0000000000f2','00000000-0000-0000-0000-0000000000f1','Gus','+15555557001');
insert into leads(id,dealer_id,contact_id,stage) values ('00000000-0000-0000-0000-0000000000f3','00000000-0000-0000-0000-0000000000f1','00000000-0000-0000-0000-0000000000f2','contacted');
insert into channel_numbers(id,dealer_id,channel,address) values ('00000000-0000-0000-0000-0000000000f4','00000000-0000-0000-0000-0000000000f1','sms','+15555559100');
\set d '\'00000000-0000-0000-0000-0000000000f1\'::uuid'
\set lead '\'00000000-0000-0000-0000-0000000000f3\'::uuid'
\set ct '\'00000000-0000-0000-0000-0000000000f2\'::uuid'
\set num '\'00000000-0000-0000-0000-0000000000f4\'::uuid'

-- AI budget: reserve before the call, settle after, hard stop, monthly rollover
do $$ begin
  update ai_budgets set monthly_cap_cents = 100 where dealer_id = '00000000-0000-0000-0000-0000000000f1';
  perform t.ok('reserve 40 ok',  ai_budget_reserve('00000000-0000-0000-0000-0000000000f1', 40));
  perform t.ok('reserve 40 ok',  ai_budget_reserve('00000000-0000-0000-0000-0000000000f1', 40));
  perform t.ok('reserve 40 blocked (would exceed 100)', not ai_budget_reserve('00000000-0000-0000-0000-0000000000f1', 40));
  perform ai_budget_settle('00000000-0000-0000-0000-0000000000f1', 40, 5);   -- real cost was 5
  perform t.eq('settle adjusts spend', (ai_budget_status('00000000-0000-0000-0000-0000000000f1')->>'spent_cents')::numeric, 45::numeric);
  perform t.ok('after settle there is room again', ai_budget_reserve('00000000-0000-0000-0000-0000000000f1', 40));
  update ai_budgets set period_start = '2026-01-01' where dealer_id = '00000000-0000-0000-0000-0000000000f1';
  perform t.ok('new month resets spend', ai_budget_reserve('00000000-0000-0000-0000-0000000000f1', 90));
  update ai_budgets set hard_stop = false where dealer_id = '00000000-0000-0000-0000-0000000000f1';
  perform t.ok('soft cap never blocks', ai_budget_reserve('00000000-0000-0000-0000-0000000000f1', 1000));
end $$;

-- circuit breaker
do $$ declare i int; begin
  perform t.ok('breaker closed initially', not agent_breaker_open('00000000-0000-0000-0000-0000000000f1'));
  for i in 1..5 loop insert into agent_runs(dealer_id,trigger,status) values ('00000000-0000-0000-0000-0000000000f1','manual','failed'); end loop;
  perform t.ok('breaker opens after 5 failures in 10 min', agent_breaker_open('00000000-0000-0000-0000-0000000000f1'));
  perform t.ok('breaker closes after cool-down window', not agent_breaker_open('00000000-0000-0000-0000-0000000000f1', now() + interval '11 minutes'));
end $$;

-- stage policy: forward-only, lost/won/back always reviewed, low confidence reviewed, humans free
select t.eq('forward + confident -> applied', apply_lead_stage(:d,:lead,'test_drive','ai',0.93,'asked to come Saturday','{"quote":"can I come Saturday?"}'), 'applied');
select t.eq('stage updated', (select stage from leads where id=:lead), 'test_drive');
select t.eq('backward -> review', apply_lead_stage(:d,:lead,'qualifying','ai',0.99,'x'), 'review');
select t.eq('stage unchanged after review', (select stage from leads where id=:lead), 'test_drive');
select t.eq('lost -> always review', apply_lead_stage(:d,:lead,'lost','ai',0.99,'bought elsewhere'), 'review');
select t.eq('low confidence -> review', apply_lead_stage(:d,:lead,'negotiating','ai',0.60,'maybe'), 'review');
select t.eq('same stage noop', apply_lead_stage(:d,:lead,'test_drive','ai',0.99,'x'), 'noop');
select t.eq('human can move back', apply_lead_stage(:d,:lead,'qualifying','human',null,'rep decision'), 'applied');
select t.eq('inbox dedupes repeated review items', (select count(*) from agent_inbox_items where lead_id=:lead and kind='classification_review' and status='open')::int, 1);
select t.eq('activity trail has quote', (select evidence->>'quote' from lead_activities where lead_id=:lead and kind='stage_changed' and actor_kind='ai'), 'can I come Saturday?');

-- drafts: hold -> due -> claim; inbound message makes pending AI drafts stale; cancels sequence follow-ups
insert into outbound_drafts(id,dealer_id,lead_id,contact_id,channel,number_id,kind,body_ai,status,release_at) values
 ('00000000-0000-0000-0000-00000000d001',:d,:lead,:ct,'sms',:num,'reply','held and due','held', now() - interval '1 minute'),
 ('00000000-0000-0000-0000-00000000d002',:d,:lead,:ct,'sms',:num,'reply','held not yet','held', now() + interval '10 minutes'),
 ('00000000-0000-0000-0000-00000000d003',:d,:lead,:ct,'sms',:num,'followup','delayed due','delayed', now() - interval '5 seconds'),
 ('00000000-0000-0000-0000-00000000d004',:d,:lead,:ct,'sms',:num,'reply','needs approval','awaiting_review', null);
do $$ declare n int; begin
  select count(*) into n from claim_due_drafts(10);
  perform t.eq('claim returns only due held/delayed drafts', n, 2);
  perform t.eq('claimed drafts are marked sending', (select count(*) from outbound_drafts where status='sending')::int, 2);
  perform t.eq('claim is not repeatable', (select count(*) from claim_due_drafts(10))::int, 0);
end $$;
insert into followups(dealer_id,lead_id,kind,due_at) values (:d,:lead,'stalled', now() + interval '1 day'), (:d,:lead,'agent_promise', now() + interval '1 day');
insert into messages(dealer_id,lead_id,contact_id,number_id,channel,direction,body) values (:d,:lead,:ct,:num,'sms','inbound','actually yes, Saturday works');
select t.eq('inbound marks pending AI drafts stale', (select count(*) from outbound_drafts where status='stale')::int, 2);
select t.eq('inbound bumps context_version', (select context_version from leads where id=:lead), 1);
select t.eq('inbound cancels stalled-follow-up sequences but keeps promises', (select string_agg(kind||':'||status, ',' order by kind) from followups where lead_id=:lead), 'agent_promise:scheduled,stalled:cancelled');

-- 48h hand-to-rep
insert into outbound_drafts(id,dealer_id,lead_id,contact_id,channel,number_id,kind,body_ai,status,created_at) values
 ('00000000-0000-0000-0000-00000000d005',:d,:lead,:ct,'sms',:num,'followup','old draft','awaiting_review', now() - interval '49 hours');
select t.eq('stale drafts handed to rep', handoff_stale_drafts(), 1);
select t.eq('draft status', (select status from outbound_drafts where id='00000000-0000-0000-0000-00000000d005'), 'handed_to_rep');
select t.eq('inbox item created', (select count(*) from agent_inbox_items where kind='stale_draft' and lead_id=:lead)::int, 1);

-- trace + tool-call tables accept rows
insert into agent_runs(id,dealer_id,lead_id,trigger,status,model,cost_cents) values ('00000000-0000-0000-0000-0000000000a0',:d,:lead,'inbound_message','completed','test-model',1.25);
insert into before_send_traces(dealer_id,draft_id,run_id,chain_version,gate,verdict,code,detail) values (:d,'00000000-0000-0000-0000-00000000d002','00000000-0000-0000-0000-0000000000a0',1,'opt_out','allow','ok','{}');
insert into agent_tool_calls(run_id,dealer_id,tool,args,result_code) values ('00000000-0000-0000-0000-0000000000a0',:d,'send_message','{}','ok');
select t.ok('prune runs', (select count(*) from before_send_traces) = 1);
\echo AGENT TESTS PASSED
