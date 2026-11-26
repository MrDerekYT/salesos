\set ON_ERROR_STOP 1
-- Phase 5: keyword-reply outbox, email suppression, WhatsApp template compliance, agent facts, staff verification.
\set d '\'00000000-0000-0000-0021-0000000000a1\'::uuid'
\set d2 '\'00000000-0000-0000-0021-0000000000a2\'::uuid'
\set now '\'2026-03-10 15:00:00+00\'::timestamptz'
insert into dealers(id,name,timezone,postal_address,main_phone) values (:d,'Gap Motors','America/New_York','1 Main St, Springfield, NJ 07081','+15555550100'),(:d2,'Other Gap','America/New_York',null,null);
insert into dealer_members(user_id,dealer_id,role) values
  ('00000000-0000-0000-0021-0000000000b1', :d, 'sales'), ('00000000-0000-0000-0021-0000000000b2', :d, 'owner'),
  ('00000000-0000-0000-0021-0000000000b3', :d, 'manager'), ('00000000-0000-0000-0021-0000000000b4', :d2, 'owner'), ('00000000-0000-0000-0021-0000000000b5', :d, 'sales');
insert into channel_numbers(id,dealer_id,channel,provider,address,activated_at,provider_config) values
 ('00000000-0000-0000-0021-0000000000d1', :d, 'sms', 'twilio', '+15555550299', '2025-01-01', '{}'),
 ('00000000-0000-0000-0021-0000000000d2', :d, 'whatsapp', 'meta_cloud', '+15555550298', '2025-01-01', '{"phone_number_id":"2090001","waba_id":"WABA-21"}'),
 ('00000000-0000-0000-0021-0000000000d3', :d, 'email', 'resend', 'sales@gap.example', '2025-01-01', '{}');
\set n1 '\'00000000-0000-0000-0021-0000000000d1\'::uuid'
\set n2 '\'00000000-0000-0000-0021-0000000000d2\'::uuid'
\set n3 '\'00000000-0000-0000-0021-0000000000d3\'::uuid'

-- ======================= 1. KEYWORD-REPLY OUTBOX =======================
create or replace function pg_temp.mk_stop(p_tag text, p_phone text, p_at timestamptz, p_kind text default 'stop') returns uuid language plpgsql as $$
declare c uuid := gen_random_uuid(); l uuid := gen_random_uuid(); m uuid := gen_random_uuid(); r uuid;
begin
  insert into contacts(id,dealer_id,first_name,phone_e164) values (c, '00000000-0000-0000-0021-0000000000a1', p_tag, p_phone);
  insert into consent_events(dealer_id,contact_id,channel,purpose,action,source,created_at) values ('00000000-0000-0000-0021-0000000000a1', c, 'sms', 'conversational', 'grant', 'web_form', now() - interval '1 day');
  insert into leads(id,dealer_id,contact_id,stage) values (l, '00000000-0000-0000-0021-0000000000a1', c, 'qualifying');
  insert into messages(id,dealer_id,lead_id,contact_id,number_id,channel,direction,body,provider_message_id,created_at)
  values (m, '00000000-0000-0000-0021-0000000000a1', l, c, '00000000-0000-0000-0021-0000000000d1', 'sms', 'inbound', upper(p_kind), 'SM-' || p_tag, p_at);
  select keyword_reply_id into r from apply_inbound_keyword(m, p_kind, 'channel', upper(p_kind), false, false, p_at);
  return r;
end $$;
create temp table kr as select pg_temp.mk_stop('K1', '+15555552101', :now) as id;
select t.eq('STOP claims one confirmation, pending, number taken from the message', (select status || ':' || (number_id = :n1)::text from keyword_replies where id = (select id from kr)), 'pending:true');
select t.eq('first attempt', (select attempts from begin_keyword_reply((select id from kr), :now)), 1);
select t.eq('row is now sending', (select status from keyword_replies where id = (select id from kr)), 'sending');
select t.eq('a second worker cannot take a sending row', (select count(*)::int from begin_keyword_reply((select id from kr), :now + interval '1 second')), 0);
select t.eq('send failed (retryable) => pending again', finish_keyword_reply((select id from kr), false, null, 'provider_unavailable', true, 'body', :now), 'pending');
select t.eq('STOP backoff is 15 s (inside the 5-minute confirmation window)', (select next_attempt_at from keyword_replies where id = (select id from kr)), :now + interval '15 seconds');
select t.eq('not due before the backoff', (select count(*)::int from begin_keyword_reply((select id from kr), :now + interval '10 seconds')), 0);
select t.eq('due after it: attempt 2', (select attempts from begin_keyword_reply((select id from kr), :now + interval '16 seconds')), 2);
select t.eq('success => sent', finish_keyword_reply((select id from kr), true, 'SM-CONF-1', null, false, 'Gap Motors: you are unsubscribed', :now + interval '17 seconds'), 'sent');
select t.eq('exactly one system message, linked', (select count(*)::int from messages where contact_id = (select contact_id from keyword_replies where id = (select id from kr)) and author_kind = 'system' and status = 'sent'), 1);
select t.ok('the reply row points at it', (select sent_message_id is not null from keyword_replies where id = (select id from kr)));
select t.eq('a sent reply can never be claimed again', (select count(*)::int from begin_keyword_reply((select id from kr), :now + interval '1 hour')), 0);
select t.eq('finish is idempotent: a late duplicate result changes nothing', finish_keyword_reply((select id from kr), true, 'SM-CONF-DUP', null, false, 'x', :now + interval '20 seconds'), 'sent');
select t.eq('...and adds no second message', (select count(*)::int from messages where author_kind = 'system' and body like 'Gap Motors: you are unsub%'), 1);

-- the 5-minute window: a late STOP confirmation is dropped, never sent
create temp table kr2 as select pg_temp.mk_stop('K2', '+15555552102', :now) as id;
select begin_keyword_reply((select id from kr2), :now);
select finish_keyword_reply((select id from kr2), false, null, 'provider_unavailable', true, 'b', :now);
select t.eq('window elapsed => expired, not sent', (select count(*)::int from begin_keyword_reply((select id from kr2), :now + interval '301 seconds')), 0);
select t.eq('...status', (select status from keyword_replies where id = (select id from kr2)), 'expired');
-- retries that cannot fit the window become gave_up with an inbox item
create temp table kr3 as select pg_temp.mk_stop('K3', '+15555552103', :now) as id;
select begin_keyword_reply((select id from kr3), :now);
select finish_keyword_reply((select id from kr3), false, null, 'provider_unavailable', true, 'b', :now + interval '1 second');           -- attempt 1 -> +15 s
select begin_keyword_reply((select id from kr3), :now + interval '20 seconds');
select finish_keyword_reply((select id from kr3), false, null, 'provider_unavailable', true, 'b', :now + interval '21 seconds');          -- attempt 2 -> +45 s
select begin_keyword_reply((select id from kr3), :now + interval '70 seconds');
select finish_keyword_reply((select id from kr3), false, null, 'provider_unavailable', true, 'b', :now + interval '71 seconds');          -- attempt 3 -> +120 s
select begin_keyword_reply((select id from kr3), :now + interval '200 seconds');
select t.eq('attempt 4 fails => gave_up', finish_keyword_reply((select id from kr3), false, null, 'provider_unavailable', true, 'b', :now + interval '201 seconds'), 'gave_up');
select t.ok('a person is told', exists (select 1 from agent_inbox_items where kind = 'send_failed' and payload->>'keyword_reply_id' = (select id::text from kr3)));
select t.eq('the failure is recorded once as a failed system message', (select count(*)::int from messages where contact_id = (select contact_id from keyword_replies where id = (select id from kr3)) and status = 'failed'), 1);
insert into messages(id,dealer_id,lead_id,contact_id,number_id,channel,direction,body,provider_message_id,created_at)
  select '00000000-0000-0000-0021-0000000000f9', dealer_id, lead_id, contact_id, number_id, channel, 'inbound', 'stop', 'SM-K3b', :now + interval '1 hour' from messages where provider_message_id = 'SM-K3';
select t.ok('a later STOP in the same cycle does NOT create another confirmation', (select reply_kind is null from apply_inbound_keyword('00000000-0000-0000-0021-0000000000f9', 'stop', 'channel', 'stop', false, false, :now + interval '1 hour')));
select t.ok('a webhook retry of the first STOP finds nothing to send (gave_up rows are not claimable)', (select count(*)::int from begin_keyword_reply((select id from kr3), :now + interval '1 hour')) = 0);
-- non-retryable outcomes
create temp table kr4 as select pg_temp.mk_stop('K4', '+15555552104', :now) as id;
select begin_keyword_reply((select id from kr4), :now);
select t.eq('carrier already blocked the recipient => carrier_blocked (expected after STOP)', finish_keyword_reply((select id from kr4), false, null, 'recipient_opted_out', false, 'b', :now), 'carrier_blocked');
select t.ok('...no inbox noise', not exists (select 1 from agent_inbox_items where payload->>'keyword_reply_id' = (select id::text from kr4)));
create temp table kr5 as select pg_temp.mk_stop('K5', '+15555552105', :now) as id;
select begin_keyword_reply((select id from kr5), :now);
select t.eq('network error mid-send => unknown, never auto-resent', finish_keyword_reply((select id from kr5), false, null, 'send_outcome_unknown', false, 'b', :now), 'unknown');
select t.eq('...unknown is not claimable', (select count(*)::int from begin_keyword_reply((select id from kr5), :now + interval '1 hour')), 0);
select t.ok('...a person checks the provider log', exists (select 1 from agent_inbox_items where payload->>'keyword_reply_id' = (select id::text from kr5) and kind = 'send_failed'));
-- re-opt-in cancels a stale STOP confirmation
create temp table kr6 as select pg_temp.mk_stop('K6', '+15555552106', :now) as id;
insert into consent_events(dealer_id,contact_id,channel,purpose,action,source) select dealer_id, contact_id, 'sms', 'conversational', 'grant', 'sms_keyword' from keyword_replies where id = (select id from kr6);
select t.eq('the customer texted START meanwhile => the STOP confirmation expires', (select count(*)::int from begin_keyword_reply((select id from kr6), :now + interval '5 seconds')), 0);
-- crash recovery
create temp table kr7 as select pg_temp.mk_stop('K7', '+15555552107', :now) as id;
select begin_keyword_reply((select id from kr7), :now);
select t.eq('a worker that died mid-send: not reclaimable at once', (select count(*)::int from claim_keyword_replies(10, :now + interval '30 seconds') where reply_id = (select id from kr7)), 0);
select t.eq('...a STOP confirmation is reclaimed after its 60 s lease (the send-attempt key decides if it already went)', (select count(*)::int from claim_keyword_replies(10, :now + interval '61 seconds') where reply_id = (select id from kr7)), 1);
create temp table kr8 as select pg_temp.mk_stop('K8', '+15555552108', :now, 'help') as id;
select begin_keyword_reply((select id from kr8), :now);
select t.eq('HELP reply has a 5-minute lease', (select count(*)::int from claim_keyword_replies(10, :now + interval '2 minutes') where reply_id = (select id from kr8)), 0);
select t.eq('...then is reclaimed (1-hour window)', (select count(*)::int from claim_keyword_replies(10, :now + interval '6 minutes') where reply_id = (select id from kr8)), 1);
select t.eq('claim_keyword_replies skips rows that are not due', (select count(*)::int from claim_keyword_replies(10, :now) ), 0);
select t.eq('policy: STOP window is 300 s', (select window_secs from keyword_reply_policy('stop')), 300);

-- ======================= 2. EMAIL BOUNCES + SUPPRESSION =======================
insert into contacts(id,dealer_id,first_name,email) values
 ('00000000-0000-0000-0021-0000000000c1', :d, 'Ed', 'ed@example.com'), ('00000000-0000-0000-0021-0000000000c2', :d, 'Flo', 'flo@example.com'),
 ('00000000-0000-0000-0021-0000000000c3', :d, 'Gil', 'gil@example.com'), ('00000000-0000-0000-0021-0000000000c4', :d2, 'Ed2', 'ed@example.com');
insert into consent_events(dealer_id,contact_id,channel,purpose,action,source) values
 (:d,'00000000-0000-0000-0021-0000000000c1','email','conversational','grant','web_form'),(:d,'00000000-0000-0000-0021-0000000000c2','email','conversational','grant','web_form'),
 (:d,'00000000-0000-0000-0021-0000000000c3','email','conversational','grant','web_form');
insert into messages(dealer_id,contact_id,number_id,channel,direction,author_kind,body,provider_message_id,status) values
 (:d,'00000000-0000-0000-0021-0000000000c1',:n3,'email','outbound','ai','x','re_b1','sent'),(:d,'00000000-0000-0000-0021-0000000000c1',:n3,'email','outbound','ai','x','re_b2','sent'),
 (:d,'00000000-0000-0000-0021-0000000000c1',:n3,'email','outbound','ai','x','re_b3','sent'),
 (:d,'00000000-0000-0000-0021-0000000000c2',:n3,'email','outbound','ai','x','re_h1','sent'),
 (:d,'00000000-0000-0000-0021-0000000000c3',:n3,'email','outbound','ai','x','re_g1','sent'),(:d,'00000000-0000-0000-0021-0000000000c3',:n3,'email','outbound','ai','x','re_g2','sent'),
 (:d,'00000000-0000-0000-0021-0000000000c3',:n3,'email','outbound','ai','x','re_g3','sent');
\set c1 '\'00000000-0000-0000-0021-0000000000c1\'::uuid'
\set c2 '\'00000000-0000-0000-0021-0000000000c2\'::uuid'
\set c3 '\'00000000-0000-0000-0021-0000000000c3\'::uuid'
select t.eq('baseline: email is allowed', (can_send(:d,:c1,'email','conversational','followup',:n3,'Hello Ed, any questions?',null,'ai',false,false,null,:now)).verdict::text, 'allow');
select t.eq('soft bounce 1: counted, not suppressed', (select suppressed::text || ':' || soft_count from record_email_bounce('re_b1','soft',null,'mailbox full','evt-1',null,:now)), 'false:1');
select t.eq('same provider event again: idempotent (no recount)', (select recorded::text || ':' || soft_count from record_email_bounce('re_b1','soft',null,'mailbox full','evt-1',null,:now)), 'false:0');
select t.eq('soft bounce 2', (select suppressed::text || ':' || soft_count from record_email_bounce('re_b2','soft',null,'mailbox full','evt-2',null,:now + interval '1 day')), 'false:2');
select t.eq('still sendable below the threshold', (can_send(:d,:c1,'email','conversational','followup',:n3,'Hello Ed, any questions?',null,'ai',false,false,null,:now + interval '1 day')).verdict::text, 'allow');
select t.eq('soft bounce 3 reaches the limit => suppressed', (select suppressed::text || ':' || reason from record_email_bounce('re_b3','soft',null,'mailbox full','evt-3',null,:now + interval '2 days')), 'true:soft_bounce_limit');
select t.eq('can_send vetoes a suppressed address', (can_send(:d,:c1,'email','conversational','followup',:n3,'Hello again',null,'ai',false,false,null,:now + interval '2 days')).code, 'email_suppressed');
select t.eq('...also with a commit', (can_send(:d,:c1,'email','conversational','reply',:n3,'Hello again',null,'ai',false,true,'k-sup',:now + interval '2 days')).verdict::text, 'veto');
select t.eq('...no reservation was taken', (select count(*)::int from send_reservations where idempotency_key = 'k-sup'), 0);
select t.ok('send target says suppressed (system emails stop too)', (get_send_target(:n3, :c1, :now)->>'email_suppressed')::boolean);
select t.ok('...and not for others', not (get_send_target(:n3, :c2, :now)->>'email_suppressed')::boolean);
select t.ok('same address at another dealer is unaffected', not is_email_suppressed(:d2, 'ed@example.com'));
select t.eq('hard bounce suppresses at once', (select suppressed::text || ':' || reason from record_email_bounce('re_h1','hard','FLO@example.com ','550 no such user','evt-4',null,:now)), 'true:hard_bounce');
select t.eq('...case-insensitive match', (can_send(:d,:c2,'email','conversational','followup',:n3,'Hello',null,'ai',false,false,null,:now)).code, 'email_suppressed');
select t.eq('unknown message + explicit address still suppresses (bounce for a send we lost track of)', (select reason from record_email_bounce('re_missing','hard','ghost@example.com','550','evt-5',:d,:now)), 'hard_bounce');
select t.eq('unknown recipient with no address is a no-op', (select reason from record_email_bounce('re_missing2','hard',null,'550','evt-6',null,:now)), 'unknown_recipient');
-- a good delivery resets the soft count
select record_email_bounce('re_g1','soft',null,'full','evt-7',null,:now);
select record_email_bounce('re_g2','soft',null,'full','evt-8',null,:now + interval '1 hour');
update messages set status = 'delivered', delivered_at = :now + interval '2 hours' where provider_message_id = 're_g1';
select t.eq('after a delivery the count restarts', (select soft_count from record_email_bounce('re_g3','soft',null,'full','evt-9',null,:now + interval '3 hours')), 1);
select t.ok('...so the address stays usable', not is_email_suppressed(:d, 'gil@example.com'));
-- soft events outside the window do not count
update dealer_settings set email_soft_bounce_limit = 2, email_soft_bounce_window_days = 7 where dealer_id = :d;
select t.eq('limit is per-dealer configurable (2 now): the 2nd soft inside 7 days suppresses', (select suppressed::text from record_email_bounce('re_g3','soft',null,'full','evt-10',null,:now + interval '4 hours')), 'true');
-- routing and clearing
insert into contacts(id,dealer_id,first_name,email,phone_e164) values ('00000000-0000-0000-0021-0000000000c5', :d, 'Hal', 'hal@example.com', '+15555552191');
select record_email_bounce('nope','hard','hal@example.com','550','evt-11',:d,:now);
select t.eq('routing skips a suppressed mailbox and falls back to SMS', (select channel::text from pick_send_route(:d, '00000000-0000-0000-0021-0000000000c5', 'email')), 'sms');
select t.raises('a rep cannot clear a suppression', $q$select clear_email_suppression('00000000-0000-0000-0021-0000000000a1','hal@example.com','customer fixed the mailbox','00000000-0000-0000-0021-0000000000b1')$q$, '%forbidden%');
select t.raises('clearing needs a real reason', $q$select clear_email_suppression('00000000-0000-0000-0021-0000000000a1','hal@example.com','ok','00000000-0000-0000-0021-0000000000b3')$q$, '%reason%');
select t.ok('a manager clears it', clear_email_suppression(:d, 'hal@example.com', 'customer confirmed the mailbox works', '00000000-0000-0000-0021-0000000000b3'));
select t.ok('...history is kept', (select cleared_at is not null and cleared_note is not null from email_suppressions where email = 'hal@example.com' and dealer_id = :d));
select t.ok('...and the address can be suppressed again later', (select suppressed from record_email_bounce('nope2','hard','hal@example.com','550','evt-12',:d,:now + interval '1 minute')));
select t.ok('manual suppression by a rep works', suppress_email(:d, 'Zed@Example.com', 'manual', 'asked by phone to stop email', '00000000-0000-0000-0021-0000000000b1'));
select t.ok('...stored lower-case', is_email_suppressed(:d, 'zed@example.com'));
select t.raises('bounce kind is validated', $q$select * from record_email_bounce('x','maybe')$q$, '%invalid bounce kind%');
-- RLS
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0021-0000000000b1"}', false);
set role authenticated;
select t.ok('members read their suppression list', (select count(*) from email_suppressions) >= 3);
select t.eq('...but not another dealer''s', (select count(*)::int from email_suppressions where dealer_id = '00000000-0000-0000-0021-0000000000a2'), 0);
select t.raises('clients cannot write suppressions directly', $q$delete from email_suppressions$q$, '%permission denied%');
reset role;
select set_config('request.jwt.claims', '', false);

-- ======================= 3. WHATSAPP TEMPLATE COMPLIANCE =======================
select t.eq('sync upserts 6', upsert_message_templates(:n2, $j$[
 {"id":"w1","name":"promo_nooptout","language":"en_US","category":"MARKETING","status":"APPROVED","body_text":"Hi {{1}}, new arrivals this weekend at {{2}}!","param_count":2},
 {"id":"w2","name":"promo_ok","language":"en_US","category":"MARKETING","status":"APPROVED","body_text":"Hi {{1}}, new arrivals at {{2}}. Reply STOP to opt out.","param_count":2},
 {"id":"w3","name":"promo_button","language":"en_US","category":"MARKETING","status":"APPROVED","body_text":"Hi {{1}}, a price drop on your {{2}}.","param_count":2,"has_opt_out_button":true},
 {"id":"w4","name":"util_plain","language":"en_US","category":"UTILITY","status":"APPROVED","body_text":"Hi {{1}}, your {{2}} service is ready.","param_count":2},
 {"id":"w5","name":"promo_empty","language":"en_US","category":"MARKETING","status":"APPROVED","body_text":"","param_count":0},
 {"id":"w6","name":"promo_pending","language":"en_US","category":"MARKETING","status":"PENDING","body_text":"Hi {{1}}. Text STOP to unsubscribe.","param_count":1}]$j$::jsonb, :now), 6);
select t.eq('marketing without opt-out wording is flagged', (select compliance_status || ':' || array_to_string(compliance_flags, ',') from message_templates where name = 'promo_nooptout'), 'flagged:missing_opt_out');
select t.eq('"Reply STOP to opt out" passes', (select compliance_status from message_templates where name = 'promo_ok'), 'ok');
select t.eq('an opt-out quick-reply button passes', (select compliance_status from message_templates where name = 'promo_button'), 'ok');
select t.eq('utility templates are not held to the marketing rule', (select compliance_status from message_templates where name = 'util_plain'), 'ok');
select t.ok('empty body is flagged too', (select 'empty_body' = any (compliance_flags) from message_templates where name = 'promo_empty'));
select t.eq('flagged templates open exactly one inbox item each', (select count(*)::int from agent_inbox_items where kind = 'needs_review' and payload->>'name' = 'promo_nooptout'), 1);
select upsert_message_templates(:n2, (select jsonb_agg(jsonb_build_object('id', provider_template_id, 'name', name, 'language', language, 'category', category, 'status', status, 'body_text', body_text, 'param_count', param_count, 'has_opt_out_button', has_opt_out_button)) from message_templates where number_id = :n2), :now + interval '1 hour');
select t.eq('re-sync does not duplicate the inbox item', (select count(*)::int from agent_inbox_items where kind = 'needs_review' and payload->>'name' = 'promo_nooptout'), 1);
select t.eq('gate: flagged marketing template is blocked', check_template_send(:n2, 'promo_nooptout', 'en_US', 'marketing')->>'code', 'template_noncompliant');
select t.eq('gate: compliant marketing template passes', (check_template_send(:n2, 'promo_ok', 'en_US', 'marketing')->>'allowed')::boolean, true);
select t.eq('gate: button-compliant passes', (check_template_send(:n2, 'promo_button', 'en_US', 'marketing')->>'allowed')::boolean, true);
select t.eq('gate: not approved is blocked', check_template_send(:n2, 'promo_pending', 'en_US', 'marketing')->>'code', 'template_not_approved');
select t.eq('gate: a UTILITY template cannot carry marketing', check_template_send(:n2, 'util_plain', 'en_US', 'marketing')->>'code', 'template_category_mismatch');
select t.eq('gate: a MARKETING template cannot be used for a service message', check_template_send(:n2, 'promo_ok', 'en_US', 'transactional')->>'code', 'template_category_mismatch');
select t.eq('gate: unknown template', check_template_send(:n2, 'nope', 'en_US', 'marketing')->>'code', 'template_unknown');
update message_templates set salesos_use = 'reengage' where number_id = :n2 and name in ('promo_nooptout','promo_ok');
select t.eq('selection offers a compliant marketing template', (select name from pick_whatsapp_template(:n2, 'zzz', 'marketing')), (select name from message_templates where name in ('promo_ok','promo_button') order by updated_at desc, name limit 1));
update message_templates set salesos_use = 'reengage' where number_id = :n2 and name = 'promo_button';
select t.ok('a flagged template is never selected for marketing', (select name from pick_whatsapp_template(:n2, 'reengage', 'marketing')) <> 'promo_nooptout');
select t.raises('a rep cannot override', $q$select override_template_compliance((select id from message_templates where name = 'promo_nooptout'), 'footer carries the opt-out text', '00000000-0000-0000-0021-0000000000b1')$q$, '%forbidden%');
select t.raises('override needs a reason', $q$select override_template_compliance((select id from message_templates where name = 'promo_nooptout'), 'fine', '00000000-0000-0000-0021-0000000000b3')$q$, '%reason%');
select t.eq('manager override', override_template_compliance((select id from message_templates where name = 'promo_nooptout'), 'Opt-out is in the Meta footer we do not receive', '00000000-0000-0000-0021-0000000000b3'), 'overridden');
select t.ok('...allowed through the gate', (check_template_send(:n2, 'promo_nooptout', 'en_US', 'marketing')->>'allowed')::boolean);
select t.ok('...the inbox item is resolved', exists (select 1 from agent_inbox_items where payload->>'name' = 'promo_nooptout' and status = 'resolved'));
select apply_template_status('WABA-21', 'w1', 'promo_nooptout', 'en_US', 'APPROVED', null, :now);
select t.eq('a status push keeps the override', (select compliance_status from message_templates where name = 'promo_nooptout'), 'overridden');
select upsert_message_templates(:n2, '[{"id":"w1","name":"promo_nooptout","language":"en_US","category":"MARKETING","status":"APPROVED","body_text":"Hi {{1}}, a new deal at {{2}}!","param_count":2}]'::jsonb, :now + interval '2 hours');
select t.eq('...but editing the template text in Meta re-checks it', (select compliance_status from message_templates where name = 'promo_nooptout'), 'flagged');
select t.eq('opt-out wording variants', (select string_agg(case when template_compliance_flags('MARKETING', b) = '{}' then 'ok' else 'no' end, ',' order by o)
   from unnest(array['Text STOP to end','Send STOP to cancel','To opt out reply 1','Unsubscribe: reply','Type "STOP" to quit','Come stop by this weekend','We opted for a new trim']) with ordinality u(b, o)), 'ok,ok,ok,ok,ok,no,no');

-- ======================= 4. AGENT CUSTOMER FACTS =======================
select t.ok('valid VIN (Honda sample)', vin_valid('1HGCM82633A004352'));
select t.ok('valid VIN with X check digit', vin_valid('1M8GDM9AXKP042788'));
select t.ok('lower-case is accepted', vin_valid('1hgcm82633a004352'));
select t.ok('one wrong digit fails the checksum', not vin_valid('1HGCM82633A004353'));
select t.ok('I/O/Q are never valid', not vin_valid('1HGCM82633A00I352') and not vin_valid('1HGCM82633A00O352'));
select t.ok('wrong length / junk', not vin_valid('1HGCM82633A00435') and not vin_valid('') and not vin_valid(null));
insert into contacts(id,dealer_id,first_name,phone_e164) values ('00000000-0000-0000-0021-0000000000c6', :d, 'Ivy', '+15555552106'),('00000000-0000-0000-0021-0000000000c7', :d, 'Jon', '+15555552107');
insert into leads(id,dealer_id,contact_id,stage) values ('00000000-0000-0000-0021-0000000000e6', :d, '00000000-0000-0000-0021-0000000000c6', 'qualifying'),('00000000-0000-0000-0021-0000000000e7', :d, '00000000-0000-0000-0021-0000000000c7', 'qualifying');
\set l6 '\'00000000-0000-0000-0021-0000000000e6\'::uuid'
\set l7 '\'00000000-0000-0000-0021-0000000000e7\'::uuid'
insert into messages(id,dealer_id,lead_id,contact_id,number_id,channel,direction,body,provider_message_id,created_at) values
 ('00000000-0000-0000-0021-0000000000f1', :d, :l6, '00000000-0000-0000-0021-0000000000c6', :n1, 'sms','inbound','My budget is around $38,000 and I want the  Limited trim', 'SM-F1', :now - interval '3 hours'),
 ('00000000-0000-0000-0021-0000000000f2', :d, :l6, '00000000-0000-0000-0021-0000000000c6', :n1, 'sms','inbound','Actually max 35k. Trade is a VIN 1HGCM82633A004352. Need to buy within 30 days, will finance', 'SM-F2', :now - interval '1 hour'),
 ('00000000-0000-0000-0021-0000000000f3', :d, :l7, '00000000-0000-0000-0021-0000000000c7', :n1, 'sms','inbound','my secret quote only on lead 7', 'SM-F3', :now - interval '1 hour');
insert into agent_runs(id, dealer_id, lead_id, trigger, status, started_at) values
 ('00000000-0000-0000-0021-0000000000aa', :d, :l6, 'inbound_message', 'running', :now), ('00000000-0000-0000-0021-0000000000ab', :d, :l7, 'inbound_message', 'running', :now);
\set r6 '\'00000000-0000-0000-0021-0000000000aa\'::uuid'
select t.eq('budget recorded with provenance', (agent_record_fact(:r6, 'budget_max_cents', '3800000'::jsonb, 0.9, 'budget is around $38,000', :now)->>'result'), 'inserted');
select t.eq('...tied to the message that says it', (select message_id from customer_facts where lead_id = :l6 and fact_key = 'budget_max_cents' and superseded_at is null), '00000000-0000-0000-0021-0000000000f1'::uuid);
select t.ok('...source/confidence/run recorded', (select source = 'ai_extracted' and confidence = 0.9 and run_id = :r6 from customer_facts where lead_id = :l6 and fact_key = 'budget_max_cents'));
select t.eq('quote matching ignores case and whitespace runs', (agent_record_fact(:r6, 'preferred_trim', '"Limited"'::jsonb, 0.8, 'WANT THE LIMITED trim', :now)->>'result'), 'inserted');
select t.eq('a newer message supersedes (history kept)', (agent_record_fact(:r6, 'budget_max_cents', '3500000'::jsonb, 0.85, 'Actually max 35k', :now + interval '1 minute')->>'result'), 'superseded');
select t.eq('...two rows, one current', (select count(*) filter (where superseded_at is null) || '/' || count(*) from customer_facts where lead_id = :l6 and fact_key = 'budget_max_cents'), '1/2');
select t.ok('...chain: new.supersedes_id = old.id', (select n.supersedes_id = o.id from customer_facts n join customer_facts o on o.lead_id = n.lead_id and o.fact_key = n.fact_key and o.superseded_at is not null where n.lead_id = :l6 and n.fact_key = 'budget_max_cents' and n.superseded_at is null));
select t.eq('the current value is the new one', (select value from customer_facts where lead_id = :l6 and fact_key = 'budget_max_cents' and superseded_at is null), '3500000'::jsonb);
select t.eq('re-stating an OLDER message cannot override the newer fact', (agent_record_fact(:r6, 'budget_max_cents', '3800000'::jsonb, 0.95, 'budget is around $38,000', :now + interval '2 minutes')->>'result'), 'stale');
select t.eq('same value again is unchanged', (agent_record_fact(:r6, 'budget_max_cents', '3500000'::jsonb, 0.9, 'max 35k', :now + interval '3 minutes')->>'result'), 'unchanged');
select t.eq('valid trade-in VIN stored upper-case', (agent_record_fact(:r6, 'trade_in_vin', '"1hgcm82633a004352"'::jsonb, 0.9, 'VIN 1HGCM82633A004352', :now)->>'result'), 'inserted');
select t.eq('...normalised', (select value #>> '{}' from customer_facts where lead_id = :l6 and fact_key = 'trade_in_vin'), '1HGCM82633A004352');
select t.eq('bad VIN checksum is rejected with a teaching message', (agent_record_fact(:r6, 'trade_in_vin', '"1HGCM82633A004353"'::jsonb, 0.9, 'VIN 1HGCM82633A004352', :now)->>'code'), 'invalid_vin');
select t.eq('timeframe enum', (agent_record_fact(:r6, 'purchase_timeframe', '"within_30_days"'::jsonb, 0.8, 'within 30 days', :now)->>'result'), 'inserted');
select t.eq('financing intent boolean', (agent_record_fact(:r6, 'wants_financing', 'true'::jsonb, 0.7, 'will finance', :now)->>'result'), 'inserted');
select t.eq('timeframe outside the enum', (agent_record_fact(:r6, 'purchase_timeframe', '"soon"'::jsonb, 0.8, 'within 30 days', :now)->>'code'), 'invalid_value');
select t.eq('financing must be a boolean', (agent_record_fact(:r6, 'wants_financing', '"yes"'::jsonb, 0.8, 'will finance', :now)->>'code'), 'invalid_value');
select t.eq('budget below the floor', (agent_record_fact(:r6, 'budget_max_cents', '500'::jsonb, 0.9, 'max 35k', :now)->>'code'), 'invalid_value');
select t.eq('budget must be whole cents', (agent_record_fact(:r6, 'budget_max_cents', '3500000.5'::jsonb, 0.9, 'max 35k', :now)->>'code'), 'invalid_value');
select t.eq('budget of the wrong JSON type', (agent_record_fact(:r6, 'budget_max_cents', '"35000"'::jsonb, 0.9, 'max 35k', :now)->>'code'), 'invalid_value');
select t.eq('low confidence is refused', (agent_record_fact(:r6, 'preferred_trim', '"Sport"'::jsonb, 0.3, 'Limited trim', :now)->>'code'), 'low_confidence');
select t.eq('an invented quote is refused', (agent_record_fact(:r6, 'preferred_trim', '"Sport"'::jsonb, 0.9, 'I love the Sport trim', :now)->>'code'), 'quote_not_found');
select t.eq('a quote from ANOTHER lead is refused (tenancy via the run)', (agent_record_fact(:r6, 'preferred_trim', '"Sport"'::jsonb, 0.9, 'my secret quote only on lead 7', :now)->>'code'), 'quote_not_found');
select t.eq('unsupported keys are refused', (agent_record_fact(:r6, 'credit_score', '700'::jsonb, 0.9, 'Limited trim', :now)->>'code'), 'invalid_key');
select t.eq('a tiny quote is refused', (agent_record_fact(:r6, 'preferred_trim', '"Sport"'::jsonb, 0.9, 'ab', :now)->>'code'), 'quote_required');
select upsert_customer_fact(:d, :l6, 'wants_financing', 'false'::jsonb, 'rep_entered', null, 'phone call', null, null, '00000000-0000-0000-0021-0000000000b1', :now + interval '4 minutes');
select t.eq('an AI guess never replaces what a rep recorded', (agent_record_fact(:r6, 'wants_financing', 'true'::jsonb, 0.9, 'will finance', :now + interval '5 minutes')->>'result'), 'kept_existing');
-- ======================= 5. STAFF PHONE VERIFICATION =======================
insert into staff_identities(id,dealer_id,user_id,channel,address,status) values
 ('00000000-0000-0000-0021-0000000000a5', :d, '00000000-0000-0000-0021-0000000000b1', 'sms', '+15555552201', 'pending'),
 ('00000000-0000-0000-0021-0000000000a6', :d, '00000000-0000-0000-0021-0000000000b5', 'sms', '+15555552202', 'pending'),
 ('00000000-0000-0000-0021-0000000000a7', :d, '00000000-0000-0000-0021-0000000000b3', 'email', 'mgr@gap.example', 'pending');
\set si1 '\'00000000-0000-0000-0021-0000000000a5\'::uuid'
\set u1 '\'00000000-0000-0000-0021-0000000000b1\'::uuid'
\set own '\'00000000-0000-0000-0021-0000000000b2\'::uuid'
select t.eq('pending identity cannot text the CRM', (select count(*)::int from resolve_staff_sender(:d, 'sms', '+15555552201')), 0);
select t.raises('a stranger cannot request a code for someone else', $q$select * from start_staff_verification('00000000-0000-0000-0021-0000000000a5', '00000000-0000-0000-0021-0000000000b5')$q$, '%forbidden%');
select t.raises('email identities are not verifiable by text', $q$select * from start_staff_verification('00000000-0000-0000-0021-0000000000a7', '00000000-0000-0000-0021-0000000000b3')$q$, '%unsupported_channel%');
create temp table v1 as select * from start_staff_verification(:si1, :u1, :now);
select t.ok('code is 6 digits', (select code ~ '^[0-9]{6}$' from v1));
select t.eq('it goes to the registered number from the dealer''s SMS number', (select to_address || '|' || number_address || '|' || provider from v1), '+15555552201|+15555550299|twilio');
select t.eq('expires in 10 minutes', (select expires_at from v1), :now + interval '10 minutes');
select t.ok('only a hash is stored', (select count(*)::int from staff_verifications where code_hash = (select code from v1)) = 0 and (select length(code_hash) = 64 from staff_verifications where id = (select verification_id from v1)));
select t.ok('...salted: the hash is not sha256(code)', (select code_hash <> encode(sha256(convert_to((select code from v1), 'UTF8')), 'hex') from staff_verifications where id = (select verification_id from v1)));
select t.raises('cooldown between codes', $q$select * from start_staff_verification('00000000-0000-0000-0021-0000000000a5', '00000000-0000-0000-0021-0000000000b1', '2026-03-10 15:00:30+00')$q$, '%cooldown%');
select mark_staff_verification_sent((select verification_id from v1), false, 'provider_unavailable', :now);
create temp table v2 as select * from start_staff_verification(:si1, :u1, :now + interval '30 seconds');
select t.ok('a failed send lifts the cooldown (the user never got the code)', (select verification_id <> (select verification_id from v1) from v2));
select t.eq('the earlier code is retired', (select count(*)::int from staff_verifications where id = (select verification_id from v1) and superseded_at is not null), 1);
select t.eq('a wrong code is refused', (select result from confirm_staff_verification(:si1, '--bad--', :u1, :now + interval '40 seconds')), 'wrong_code');
select t.eq('wrong code counts attempts', (select attempts from staff_verifications where id = (select verification_id from v2)), 1);
select t.raises('only the person themselves can confirm (an admin cannot)', $q$select * from confirm_staff_verification('00000000-0000-0000-0021-0000000000a5', '000000', '00000000-0000-0000-0021-0000000000b2')$q$, '%forbidden%');
create temp table lockres(o int, r text);
insert into lockres select 1, result from confirm_staff_verification(:si1, '--bad--', :u1, :now + interval '50 seconds');
insert into lockres select 2, result from confirm_staff_verification(:si1, '--bad--', :u1, :now + interval '50 seconds');
insert into lockres select 3, result from confirm_staff_verification(:si1, '--bad--', :u1, :now + interval '50 seconds');
insert into lockres select 4, result from confirm_staff_verification(:si1, '--bad--', :u1, :now + interval '50 seconds');
select t.eq('4 more wrong guesses => locked on the 5th attempt', (select string_agg(r, ',' order by o) from lockres), 'wrong_code,wrong_code,wrong_code,locked');
select t.eq('even the right code is refused after the lockout', (select result from confirm_staff_verification(:si1, (select code from v2), :u1, :now + interval '60 seconds')), 'locked');
select t.eq('still cannot text the CRM', (select count(*)::int from resolve_staff_sender(:d, 'sms', '+15555552201')), 0);
create temp table v3 as select * from start_staff_verification(:si1, :own, :now + interval '2 minutes');       -- an owner may start one for the user
select t.eq('an expired code is refused', (select result from confirm_staff_verification(:si1, (select code from v3), :u1, :now + interval '13 minutes')), 'expired');
select t.raises('3 codes per hour: the 4th is refused', $q$select * from start_staff_verification('00000000-0000-0000-0021-0000000000a5', '00000000-0000-0000-0021-0000000000b1', '2026-03-10 15:30:00+00')$q$, '%rate_limited%');
create temp table v4 as select * from start_staff_verification(:si1, :u1, :now + interval '70 minutes');
select t.eq('a fresh code verifies', (select result from confirm_staff_verification(:si1, (select code from v4), :u1, :now + interval '71 minutes')), 'verified');
select t.eq('identity is active and stamped', (select status || ':' || (verified_at = :now + interval '71 minutes')::text from staff_identities where id = :si1), 'active:true');
select t.eq('NOW the number can text the CRM', (select role from resolve_staff_sender(:d, 'sms', '+15555552201')), 'sales');
select t.ok('the used code is consumed', (select consumed_at is not null from staff_verifications where id = (select verification_id from v4)));
select t.eq('replaying the code does nothing harmful', (select result from confirm_staff_verification(:si1, (select code from v4), :u1, :now + interval '72 minutes')), 'verified');
select t.raises('an active identity needs no new code', $q$select * from start_staff_verification('00000000-0000-0000-0021-0000000000a5', '00000000-0000-0000-0021-0000000000b1', '2026-03-10 17:00:00+00')$q$, '%already verified%');
-- clients cannot bypass the flow
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0021-0000000000b2"}', false);
set role authenticated;
select t.raises('an admin cannot insert an already-active identity', $q$insert into staff_identities(dealer_id,user_id,channel,address,status,verified_at) values ('00000000-0000-0000-0021-0000000000a1','00000000-0000-0000-0021-0000000000b1','sms','+15555552299','active',now())$q$, '%verified by a texted code%');
select t.raises('...nor flip one to active', $q$update staff_identities set status = 'active', verified_at = now() where id = '00000000-0000-0000-0021-0000000000a6'$q$, '%only the verification code flow%');
select t.raises('...nor set verified_at alone', $q$update staff_identities set verified_at = now() where id = '00000000-0000-0000-0021-0000000000a6'$q$, '%only the verification code flow%');
update staff_identities set address = '+15555552250' where id = '00000000-0000-0000-0021-0000000000a5';
reset role;
select set_config('request.jwt.claims', '', false);
select t.eq('changing the trusted number drops the identity back to pending', (select status || ':' || coalesce(verified_at::text, 'null') from staff_identities where id = :si1), 'pending:null');
select t.eq('...and neither number resolves any more', (select count(*)::int from resolve_staff_sender(:d, 'sms', '+15555552201')) + (select count(*)::int from resolve_staff_sender(:d, 'sms', '+15555552250')), 0);
update channel_numbers set status = 'paused' where id = :n1;
select t.raises('no active number => clear error', $q$select * from start_staff_verification('00000000-0000-0000-0021-0000000000a6', '00000000-0000-0000-0021-0000000000b5', '2026-03-10 18:00:00+00')$q$, '%no_sending_number%');
update channel_numbers set status = 'active' where id = :n1;
select t.ok('the agent sees only current facts', (select (jsonb_object_agg(f.fact_key, f.value)) @> '{"budget_max_cents":3500000}'::jsonb from customer_facts f where f.lead_id = :l6 and f.superseded_at is null));
\echo OFFLINE GAPS TESTS PASSED
