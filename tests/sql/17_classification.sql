\set ON_ERROR_STOP 1
-- Feature 5: classification lifecycle, deterministic apply policy, staleness, undo, timeline
\set d '\'00000000-0000-0000-0017-0000000000a1\'::uuid'
\set now '\'2026-03-10 15:00:00+00\'::timestamptz'
insert into dealers(id,name) values (:d,'Class Motors'),('00000000-0000-0000-0017-0000000000a2','Class Other');
insert into dealer_members(user_id,dealer_id,role) values
 ('00000000-0000-0000-0017-0000000000b1', :d, 'sales'),
 ('00000000-0000-0000-0017-0000000000b2','00000000-0000-0000-0017-0000000000a2','owner'),
 ('00000000-0000-0000-0017-0000000000b3', :d, 'viewer');
insert into contacts(id,dealer_id,first_name,phone_e164)
select ('00000000-0000-0000-0017-0000000000c' || g)::uuid, :d, 'C' || g, '+155555170' || lpad(g::text, 2, '0') from generate_series(1,9) g;
insert into leads(id,dealer_id,contact_id,stage)
select ('00000000-0000-0000-0017-0000000000e' || g)::uuid, :d, ('00000000-0000-0000-0017-0000000000c' || g)::uuid,
       (array['contacted','contacted','test_drive','qualifying','qualifying','won','contacted','contacted','contacted'])[g] from generate_series(1,9) g;
-- one inbound per lead (ids ...f1..f9)
insert into messages(id,dealer_id,lead_id,contact_id,channel,direction,body)
select ('00000000-0000-0000-0017-0000000000f' || g)::uuid, :d, ('00000000-0000-0000-0017-0000000000e' || g)::uuid, ('00000000-0000-0000-0017-0000000000c' || g)::uuid, 'sms', 'inbound',
       (array['can I come Saturday to drive it?','what''s your best out the door price','just browsing for now','we bought one elsewhere, thanks',
              'please do not contact me again','can I test drive the new one?','ok let''s do the paperwork','hi','is it still there'])[g]
  from generate_series(1,9) g;
\set m1 '\'00000000-0000-0000-0017-0000000000f1\'::uuid'

-- high confidence forward move => applied, with the customer's quote on the timeline
select t.eq('test_drive_requested 0.93 => auto_applied', (select status::text from record_classification(:m1, 'test_drive_requested', 0.93, 'can I come Saturday to drive it?', 'asks for a drive', 'llm', 'm', 'v1')), 'auto_applied');
select t.eq('lead moved forward', (select stage from leads where id = '00000000-0000-0000-0017-0000000000e1'), 'test_drive');
select t.ok('timeline row quotes the customer', (select reason ~ 'can I come Saturday' and kind = 'stage_changed' and actor_kind = 'ai' from lead_activities where lead_id = '00000000-0000-0000-0017-0000000000e1' order by created_at desc limit 1));
select t.raises('one live classification per message', $q$select * from record_classification('00000000-0000-0000-0017-0000000000f1', 'other', 0.5, null, null)$q$, '%duplicate key%');

-- below threshold => proposed + inbox; accept applies it
select t.eq('price_shopper 0.6 => proposed', (select status::text from record_classification('00000000-0000-0000-0017-0000000000f2', 'ready_to_buy', 0.6, 'best out the door price', null)), 'proposed');
select t.eq('lead unchanged while proposed', (select stage from leads where id = '00000000-0000-0000-0017-0000000000e2'), 'contacted');
select t.ok('review item opened', exists (select 1 from agent_inbox_items where lead_id = '00000000-0000-0000-0017-0000000000e2' and kind = 'classification_review' and status = 'open'));
select t.ok('accept (service role acting for the rep)', accept_classification((select id from classifications where message_id = '00000000-0000-0000-0017-0000000000f2'), '00000000-0000-0000-0017-0000000000b1') is not null);
select t.eq('accepted => stage applied by a human', (select stage from leads where id = '00000000-0000-0000-0017-0000000000e2'), 'negotiating');
select t.eq('status accepted', (select status::text from classifications where message_id = '00000000-0000-0000-0017-0000000000f2'), 'accepted');
select t.ok('review item resolved', not exists (select 1 from agent_inbox_items where lead_id = '00000000-0000-0000-0017-0000000000e2' and kind = 'classification_review' and status = 'open'));

-- forward-only: a "backward" label never moves the lead
select t.eq('just_looking on a test_drive lead => auto_applied, no move', (select status::text from record_classification('00000000-0000-0000-0017-0000000000f3', 'just_looking', 0.95, 'just browsing for now', null)), 'auto_applied');
select t.eq('stage kept', (select stage from leads where id = '00000000-0000-0000-0017-0000000000e3'), 'test_drive');
select t.eq('timeline note only', (select kind from lead_activities where lead_id = '00000000-0000-0000-0017-0000000000e3' order by created_at desc limit 1), 'classified');

-- bought_elsewhere: never automatic, even at 0.99
select t.eq('bought_elsewhere 0.99 => proposed (lost always needs a person)', (select status::text from record_classification('00000000-0000-0000-0017-0000000000f4', 'bought_elsewhere', 0.99, 'we bought one elsewhere', null)), 'proposed');
select t.eq('proposed target is lost', (select proposed_stage from classifications where message_id = '00000000-0000-0000-0017-0000000000f4'), 'lost');
select t.eq('lead not lost yet', (select stage from leads where id = '00000000-0000-0000-0017-0000000000e4'), 'qualifying');
select reject_classification((select id from classifications where message_id = '00000000-0000-0000-0017-0000000000f4'), '00000000-0000-0000-0017-0000000000b1');
select t.eq('reject => rejected', (select status::text from classifications where message_id = '00000000-0000-0000-0017-0000000000f4'), 'rejected');

-- do_not_contact: immediate, all channels
select t.eq('do_not_contact => auto_applied immediately', (select status::text from record_classification('00000000-0000-0000-0017-0000000000f5', 'do_not_contact', 0.7, 'please do not contact me again', null)), 'auto_applied');
select t.ok('all-channel DNC opened from the inbound', exists (select 1 from contact_dnc where contact_id = '00000000-0000-0000-0017-0000000000c5' and channel is null and cleared_at is null and source = 'inbound_message'));
select t.ok('urgent inbox item for a person', exists (select 1 from agent_inbox_items where lead_id = '00000000-0000-0000-0017-0000000000e5' and kind = 'ambiguous_stop' and priority = 1));

-- closed lead: even a strong signal is only a proposal
select t.eq('won lead + test drive request => proposed', (select status::text from record_classification('00000000-0000-0000-0017-0000000000f6', 'test_drive_requested', 0.97, 'can I test drive the new one?', null)), 'proposed');

-- dealer threshold and kill switch
update dealer_settings set classify_min_confidence = 0.95 where dealer_id = :d;
select t.eq('dealer threshold 0.95: 0.93 => proposed', (select status::text from record_classification('00000000-0000-0000-0017-0000000000f7', 'ready_to_buy', 0.93, 'let''s do the paperwork', null)), 'proposed');
update dealer_settings set classify_min_confidence = 0.85, classify_auto_apply = false where dealer_id = :d;
select t.eq('auto-apply off: 0.99 => proposed', (select status::text from record_classification('00000000-0000-0000-0017-0000000000f8', 'financing_prequal', 0.99, 'hi', null)), 'proposed');
update dealer_settings set classify_auto_apply = true where dealer_id = :d;

-- staleness: a newer customer message invalidates open proposals; old context_version => stale on arrival
insert into messages(dealer_id,lead_id,contact_id,channel,direction,body) values (:d,'00000000-0000-0000-0017-0000000000e8','00000000-0000-0000-0017-0000000000c8','sms','inbound','actually wait');
select t.eq('newer inbound => proposal stale', (select status::text from classifications where message_id = '00000000-0000-0000-0017-0000000000f8'), 'stale');
select t.eq('classification computed on old context => stale', (select status::text from record_classification('00000000-0000-0000-0017-0000000000f9', 'test_drive_requested', 0.99, 'is it still there', null, 'llm', null, null, 0)), 'stale');
select t.raises('stale proposals cannot be accepted', $q$select accept_classification((select id from classifications where message_id = '00000000-0000-0000-0017-0000000000f8'), '00000000-0000-0000-0017-0000000000b1')$q$, '%not proposed%');

-- failures are recorded and retryable
insert into messages(id,dealer_id,lead_id,contact_id,channel,direction,body) values ('00000000-0000-0000-0017-0000000000fa', :d,'00000000-0000-0000-0017-0000000000e9','00000000-0000-0000-0017-0000000000c9','sms','inbound','what colors?');
select t.ok('classifier failure recorded', record_classification_failure('00000000-0000-0000-0017-0000000000fa', 'timeout') is not null);
select t.eq('failed row does not block a retry', (select status::text from record_classification('00000000-0000-0000-0017-0000000000fa', 'other', 0.5, null, null, 'rule')), 'auto_applied');

-- undo + override
\set act1 '(select activity_id from classifications where message_id = \'00000000-0000-0000-0017-0000000000f1\')'
select t.ok('undo the AI move', undo_stage_change(:act1, '00000000-0000-0000-0017-0000000000b1', 'wrong lead') is not null);
select t.eq('stage restored', (select stage from leads where id = '00000000-0000-0000-0017-0000000000e1'), 'contacted');
select t.eq('classification marked rejected by the undo', (select status::text from classifications where message_id = '00000000-0000-0000-0017-0000000000f1'), 'rejected');
select t.raises('undo is one-shot', $q$select undo_stage_change((select activity_id from classifications where message_id = '00000000-0000-0000-0017-0000000000f1'), '00000000-0000-0000-0017-0000000000b1')$q$, '%already undone%');
-- only the latest change is undoable
do $$ declare a1 uuid; begin
  perform apply_lead_stage('00000000-0000-0000-0017-0000000000a1','00000000-0000-0000-0017-0000000000e3','negotiating','human',null,'rep moved',  '{}', 0.85, '00000000-0000-0000-0017-0000000000b1');
  select id into a1 from lead_activities where lead_id = '00000000-0000-0000-0017-0000000000e3' and kind = 'stage_changed' order by created_at desc limit 1;
  perform apply_lead_stage('00000000-0000-0000-0017-0000000000a1','00000000-0000-0000-0017-0000000000e3','won','human',null,'rep closed', '{}', 0.85, '00000000-0000-0000-0017-0000000000b1');
  perform t.raises('older change cannot be undone after a newer one', format('select undo_stage_change(%L, %L)', a1, '00000000-0000-0000-0017-0000000000b1'), '%undo the newer change first%');
end $$;
-- override a proposal with a different stage
select t.ok('override proposal', override_classification((select id from classifications where message_id = '00000000-0000-0000-0017-0000000000f7'), 'qualified', '00000000-0000-0000-0017-0000000000b1') is not null);
select t.eq('override applied', (select stage || '/' || (select status::text from classifications where message_id = '00000000-0000-0000-0017-0000000000f7') from leads where id = '00000000-0000-0000-0017-0000000000e7'), 'qualified/overridden');

-- staff RPCs through RLS (auth.uid())
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0017-0000000000b2"}', false);
set role authenticated;
select t.raises('other dealer''s owner cannot accept', $q$select accept_classification((select id from classifications where message_id = '00000000-0000-0000-0017-0000000000f6'))$q$, '%');
reset role;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0017-0000000000b3"}', false);
set role authenticated;
select t.raises('viewer cannot accept', $q$select accept_classification((select id from classifications where message_id = '00000000-0000-0000-0017-0000000000f6'))$q$, '%forbidden%');
reset role;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0017-0000000000b1"}', false);
set role authenticated;
select t.ok('rep accepts reopening the won lead (as themselves)', accept_classification((select id from classifications where message_id = '00000000-0000-0000-0017-0000000000f6')) is not null);
select t.eq('rep sees the timeline incl. messages', (select count(*) from v_lead_timeline where lead_id = '00000000-0000-0000-0017-0000000000e1' and item_type = 'message')::int, 1);
select t.ok('timeline marks undone change as not undoable', not (select bool_or(undoable) from v_lead_timeline where lead_id = '00000000-0000-0000-0017-0000000000e1'));
select t.raises('rep cannot call record_classification', $q$select * from record_classification('00000000-0000-0000-0017-0000000000f9','other',0.5,null,null)$q$, '%permission denied%');
select t.raises('rep cannot write classifications directly', $q$update classifications set status = 'accepted'$q$, '%permission denied%');
reset role;
select set_config('request.jwt.claims', '', false);
select t.eq('accepted by the signed-in rep', (select decided_by::text from classifications where message_id = '00000000-0000-0000-0017-0000000000f6'), '00000000-0000-0000-0017-0000000000b1');
select 'CLASSIFICATION TESTS PASSED';
