\set ON_ERROR_STOP 1
-- Phase 4 runtime: idempotent sends, inbound threading, keywords-first, receipts, templates, event log, agent lanes,
-- run start outcomes, rep approval, one-click unsubscribe, agent tool RPCs, RLS/grants, cron.
\set d '\'00000000-0000-0000-0019-0000000000a1\'::uuid'
\set now '\'2026-03-10 15:00:00+00\'::timestamptz'
insert into dealers(id,name,timezone,postal_address,main_phone) values (:d,'Runtime Motors','America/New_York','1 Main St, Springfield, NJ 07081','+15555550100'),
  ('00000000-0000-0000-0019-0000000000a2','Other Motors','America/New_York',null,null);
insert into dealer_members(user_id,dealer_id,role) values ('00000000-0000-0000-0019-0000000000b1', :d, 'sales'), ('00000000-0000-0000-0019-0000000000b2','00000000-0000-0000-0019-0000000000a2','owner');
insert into channel_numbers(id,dealer_id,channel,provider,address,activated_at,provider_config) values
 ('00000000-0000-0000-0019-0000000000d1', :d, 'sms', 'twilio', '+15555550199', '2025-01-01', '{"messaging_service_sid":"MG00000000000000000000000000000001"}'),
 ('00000000-0000-0000-0019-0000000000d2', :d, 'whatsapp', 'meta_cloud', '+15555550198', '2025-01-01', '{"phone_number_id":"1090001","waba_id":"WABA-19"}'),
 ('00000000-0000-0000-0019-0000000000d3', :d, 'email', 'resend', 'sales@runtime.example', '2025-01-01', '{}');
\set n1 '\'00000000-0000-0000-0019-0000000000d1\'::uuid'
select t.raises('provider must be a known adapter', $q$insert into channel_numbers(dealer_id,channel,provider,address) values ('00000000-0000-0000-0019-0000000000a1','sms','carrier_x','+15555550111')$q$, '%channel_numbers_provider_ck%');

-- ======================= A. send attempts (idempotency keys) =======================
select t.eq('first claim proceeds', (select decision from claim_send_attempt(:d, 'draft:A1', 'twilio', null, false, interval '10 minutes', :now)), 'proceed');
select t.eq('concurrent claim is in_flight', (select decision from claim_send_attempt(:d, 'draft:A1', 'twilio', null, false, interval '10 minutes', :now + interval '1 minute')), 'in_flight');
select complete_send_attempt(:d, 'draft:A1', true, 'SM-A1', null, :now);
select t.eq('after success: already_sent with the first provider id', (select decision || ':' || provider_message_id from claim_send_attempt(:d, 'draft:A1', 'twilio', null, false, interval '10 minutes', :now + interval '2 minutes')), 'already_sent:SM-A1');
select claim_send_attempt(:d, 'draft:A2', 'twilio', null, false, interval '10 minutes', :now);
select t.eq('stale pending on a non-idempotent provider => unknown (a person checks)', (select decision from claim_send_attempt(:d, 'draft:A2', 'twilio', null, false, interval '10 minutes', :now + interval '11 minutes')), 'unknown');
select t.eq('unknown is sticky', (select decision from claim_send_attempt(:d, 'draft:A2', 'twilio', null, false, interval '10 minutes', :now + interval '30 minutes')), 'unknown');
select claim_send_attempt(:d, 'draft:A3', 'resend', null, true, interval '10 minutes', :now);
select t.eq('stale pending on an idempotent provider (Resend) => retried with the same key', (select decision from claim_send_attempt(:d, 'draft:A3', 'resend', null, true, interval '10 minutes', :now + interval '11 minutes')), 'proceed');
select claim_send_attempt(:d, 'draft:A4', 'twilio', null, false, interval '10 minutes', :now);
select complete_send_attempt(:d, 'draft:A4', false, null, 'provider_unavailable', :now);
select t.eq('a provider rejection can be retried', (select decision from claim_send_attempt(:d, 'draft:A4', 'twilio', null, false, interval '10 minutes', :now + interval '1 minute')), 'proceed');
select t.eq('retry counted', (select attempts from send_attempts where idempotency_key = 'draft:A4'), 2);

-- released reservation does not block a retry with the same key
insert into contacts(id,dealer_id,first_name,phone_e164,email) values ('00000000-0000-0000-0019-0000000000c1', :d, 'Rita', '+15555551901', 'rita@example.com');
insert into consent_events(dealer_id,contact_id,channel,purpose,action,source) values (:d,'00000000-0000-0000-0019-0000000000c1','sms','conversational','grant','web_form');
insert into leads(id,dealer_id,contact_id,stage) values ('00000000-0000-0000-0019-0000000000e1', :d, '00000000-0000-0000-0019-0000000000c1', 'contacted');
insert into messages(dealer_id,lead_id,contact_id,number_id,channel,direction,body,created_at) values (:d,'00000000-0000-0000-0019-0000000000e1','00000000-0000-0000-0019-0000000000c1',:n1,'sms','inbound','hi', :now - interval '5 minutes');
create temp table r1 as select (can_send(:d,'00000000-0000-0000-0019-0000000000c1','sms','conversational','reply',:n1,'Happy to help, what time works?','00000000-0000-0000-0019-0000000000e1','ai',false,true,'draft:R1',:now)).*;
select t.eq('commit with a key reserves', (select verdict::text from r1), 'allow');
select t.eq('replay of the key while reserved is idempotent', (select (can_send(:d,'00000000-0000-0000-0019-0000000000c1','sms','conversational','reply',:n1,'Happy to help, what time works?','00000000-0000-0000-0019-0000000000e1','ai',false,true,'draft:R1',:now)).code), 'idempotent_replay');
select release_send((select reservation_id from r1), 'provider_unavailable');
select t.ok('after release the same key reserves a NEW slot', (select (can_send(:d,'00000000-0000-0000-0019-0000000000c1','sms','conversational','reply',:n1,'Happy to help, what time works?','00000000-0000-0000-0019-0000000000e1','ai',false,true,'draft:R1',:now + interval '2 minutes')).reservation_id) <> (select reservation_id from r1));

-- ======================= B. inbound threading =======================
select t.eq('resolve by E.164', (select number_id from resolve_inbound_number('sms', '+15555550199')), :n1);
select t.eq('resolve WhatsApp by phone_number_id', (select number_id from resolve_inbound_number('whatsapp', '1090001')), '00000000-0000-0000-0019-0000000000d2'::uuid);
select t.eq('resolve email case-insensitively', (select number_id from resolve_inbound_number('email', 'Sales@Runtime.Example')), '00000000-0000-0000-0019-0000000000d3'::uuid);
select t.ok('unknown number resolves to nothing', not exists (select 1 from resolve_inbound_number('sms', '+15550000000')));
create temp table i1 as select * from ingest_inbound_message(:n1, '+15555551999', 'Is the Tacoma still there?', 'SM-IN-1', :now, null, 'Nadia');
select t.ok('new sender => new contact + lead + conversation', (select contact_id is not null and lead_id is not null and conversation_id is not null and not duplicate from i1));
select t.eq('contact got the first name', (select first_name from contacts where id = (select contact_id from i1)), 'Nadia');
select t.eq('new lead starts at new', (select stage from leads where id = (select lead_id from i1)), 'new');
select t.eq('context_version bumped by the message trigger', (select context_version from leads where id = (select lead_id from i1)), 1);
select t.ok('webhook retry is a duplicate (same message id)', (select duplicate and message_id = (select message_id from i1) from ingest_inbound_message(:n1, '+15555551999', 'Is the Tacoma still there?', 'SM-IN-1', :now)));
select t.eq('still one message', (select count(*)::int from messages where provider_message_id = 'SM-IN-1'), 1);
create temp table i2 as select * from ingest_inbound_message(:n1, '+15555551999', 'the silver one', 'SM-IN-2', :now + interval '10 seconds');
select t.ok('same sender => same contact, lead and conversation', (select i2.contact_id = i1.contact_id and i2.lead_id = i1.lead_id and i2.conversation_id = i1.conversation_id from i1, i2));
select t.eq('existing contact (by phone) is reused', (select contact_id from ingest_inbound_message(:n1, '+15555551901', 'hello again', 'SM-IN-3', :now)), '00000000-0000-0000-0019-0000000000c1'::uuid);
select t.eq('...and its open lead', (select lead_id from messages where provider_message_id = 'SM-IN-3'), '00000000-0000-0000-0019-0000000000e1'::uuid);
select t.raises('bad sender address rejected', $q$select * from ingest_inbound_message('00000000-0000-0000-0019-0000000000d1', 'not-a-number', 'x', 'SM-BAD')$q$, '%invalid sender%');
select t.raises('provider id required', $q$select * from ingest_inbound_message('00000000-0000-0000-0019-0000000000d1', '+15555551999', 'x', '')$q$, '%provider message id%');

-- ======================= C. keywords first =======================
select t.eq('normal text => agent', (select action from apply_inbound_keyword((select message_id from i1), 'none', 'channel', null, false, false, :now)), 'agent');
select t.eq('one queued agent job', (select count(*)::int from agent_jobs where lead_id = (select lead_id from i1) and status = 'queued'), 1);
select t.eq('debounced 4 s', (select not_before from agent_jobs where lead_id = (select lead_id from i1)), :now + interval '4 seconds');
select t.eq('queued for classification', (select count(*)::int from classify_queue where message_id = (select message_id from i1)), 1);
select apply_inbound_keyword((select message_id from i2), 'none', 'channel', null, false, false, :now + interval '10 seconds');
select t.eq('burst folds into the same job (one lane)', (select count(*)::int from agent_jobs where lead_id = (select lead_id from i1)), 1);
select t.eq('job now points at the latest message', (select trigger_ref from agent_jobs where lead_id = (select lead_id from i1)), (select message_id from i2));
select t.eq('re-applying a message is a no-op', (select action from apply_inbound_keyword((select message_id from i1), 'stop', 'channel', 'stop', false, false, :now)), 'already_processed');
select t.ok('...and recorded no opt-out', not exists (select 1 from contact_dnc where contact_id = (select contact_id from i1)));

-- STOP cycle
create temp table s1 as select * from ingest_inbound_message(:n1, '+15555551999', 'STOP', 'SM-STOP-1', :now + interval '1 minute');
create temp table k1 as select * from apply_inbound_keyword((select message_id from s1), 'stop', 'channel', 'stop', false, false, :now + interval '1 minute');
select t.eq('STOP => opted_out', (select action from k1), 'opted_out');
select t.eq('STOP => one confirmation due', (select reply_kind from k1), 'stop');
select t.ok('DNC open on sms', exists (select 1 from contact_dnc where contact_id = (select contact_id from s1) and channel = 'sms' and cleared_at is null));
select t.eq('queued agent job cancelled by STOP', (select status from agent_jobs where lead_id = (select lead_id from i1)), 'skipped');
create temp table s2 as select * from ingest_inbound_message(:n1, '+15555551999', 'stop', 'SM-STOP-2', :now + interval '2 minutes');
select t.ok('second STOP: no second confirmation', (select reply_kind is null and action = 'opted_out' from apply_inbound_keyword((select message_id from s2), 'stop', 'channel', 'stop', false, false, :now + interval '2 minutes')));
select t.eq('one stop reply row', (select count(*)::int from keyword_replies where contact_id = (select contact_id from s1) and kind = 'stop'), 1);
select t.ok('no agent job after STOP', not exists (select 1 from agent_jobs where lead_id = (select lead_id from i1) and status = 'queued'));
create temp table st as select * from ingest_inbound_message(:n1, '+15555551999', 'START', 'SM-START-1', :now + interval '3 minutes');
create temp table k3 as select * from apply_inbound_keyword((select message_id from st), 'start', 'channel', 'start', false, false, :now + interval '3 minutes');
select t.ok('START => opted_in with one confirmation', (select action = 'opted_in' and reply_kind = 'start' from k3));
select t.ok('START clears the sms DNC (contact-initiated)', not exists (select 1 from contact_dnc where contact_id = (select contact_id from s1) and cleared_at is null));
create temp table s3 as select * from ingest_inbound_message(:n1, '+15555551999', 'STOP', 'SM-STOP-3', :now + interval '4 minutes');
select t.eq('new opt-out after re-opt-in => confirmed again', (select reply_kind from apply_inbound_keyword((select message_id from s3), 'stop', 'channel', 'stop', false, false, :now + interval '4 minutes')), 'stop');

-- HELP: at most hourly
create temp table h1 as select * from ingest_inbound_message(:n1, '+15555551901', 'HELP', 'SM-HELP-1', :now);
create temp table h2 as select * from ingest_inbound_message(:n1, '+15555551901', 'help', 'SM-HELP-2', :now + interval '5 minutes');
select t.eq('HELP => reply', (select reply_kind from apply_inbound_keyword((select message_id from h1), 'help', 'channel', 'help', false, false, :now)), 'help');
select t.ok('HELP again within the hour => no reply', (select reply_kind is null from apply_inbound_keyword((select message_id from h2), 'help', 'channel', 'help', false, false, :now + interval '5 minutes')));
-- provider handles keywords (Twilio Advanced Opt-Out): opt-out recorded, no reply from us
insert into contacts(id,dealer_id,phone_e164) values ('00000000-0000-0000-0019-0000000000c2', :d, '+15555551902');
create temp table s4 as select * from ingest_inbound_message(:n1, '+15555551902', 'STOP', 'SM-STOP-4', :now);
select t.ok('provider-handled STOP: recorded, no reply claimed', (select action = 'opted_out' and reply_kind is null from apply_inbound_keyword((select message_id from s4), 'stop', 'channel', 'stop', false, true, :now)));
-- probable stop
create temp table p1 as select * from ingest_inbound_message(:n1, '+15555551903', 'please take me off your list', 'SM-PS-1', :now);
select t.eq('probable stop => silenced', (select action from apply_inbound_keyword((select message_id from p1), 'probable_stop', 'channel', null, false, false, :now)), 'silenced');
select t.ok('lead owned by a person for 30 days', (select force_human and bot_silenced_until = :now + interval '30 days' from leads where id = (select lead_id from p1)));
select t.eq('urgent ambiguous_stop inbox item', (select priority::int from agent_inbox_items where lead_id = (select lead_id from p1) and kind = 'ambiguous_stop'), 1);
select t.ok('no agent job, no classification', not exists (select 1 from agent_jobs where lead_id = (select lead_id from p1)) and not exists (select 1 from classify_queue where message_id = (select message_id from p1)));
-- all-channel STOP then START is blocked
create temp table a1 as select * from ingest_inbound_message(:n1, '+15555551904', 'stop all messages everywhere', 'SM-ALL-1', :now);
select apply_inbound_keyword((select message_id from a1), 'stop', 'all_channels', 'stop all', false, false, :now);
create temp table a2 as select * from ingest_inbound_message(:n1, '+15555551904', 'START', 'SM-ALL-2', :now + interval '1 minute');
select t.eq('START cannot clear an all-channel DNC', (select action from apply_inbound_keyword((select message_id from a2), 'start', 'channel', 'start', false, false, :now + interval '1 minute')), 'start_blocked');

-- system message threading
create temp table sm as select record_system_message(:n1, (select contact_id from s1), 'Runtime Motors: You''re unsubscribed', 'SM-OUT-STOP', 'sent', (select keyword_reply_id from k1), null, :now) id;
select t.ok('system reply recorded on the conversation', (select conversation_id is not null and author_kind = 'system' from messages where id = (select id from sm)));
select t.ok('keyword reply linked to the sent message', (select sent_message_id is not null from keyword_replies where id = (select keyword_reply_id from k1)));

-- ======================= D. delivery receipts =======================
insert into messages(id,dealer_id,lead_id,contact_id,number_id,channel,direction,author_kind,body,provider_message_id,status) values
 ('00000000-0000-0000-0019-0000000000f1', :d, '00000000-0000-0000-0019-0000000000e1','00000000-0000-0000-0019-0000000000c1',:n1,'sms','outbound','ai','x','SM-OUT-1','sent');
select t.ok('sent -> delivered applies', (select applied from apply_message_status('sms','SM-OUT-1','delivered',null,:now)));
select t.ok('late "sent" does not move it back', (select not applied from apply_message_status('sms','SM-OUT-1','sent',null,:now)));
select t.ok('failed never overwrites delivered', (select not applied from apply_message_status('sms','SM-OUT-1','failed','30003',:now)));
select t.eq('status delivered', (select status from messages where id = '00000000-0000-0000-0019-0000000000f1'), 'delivered');
select apply_message_status('sms','SM-OUT-1','read',null,:now + interval '1 minute');
select t.ok('read sets read_at, keeps delivered_at', (select status = 'read' and read_at is not null and delivered_at = :now from messages where id = '00000000-0000-0000-0019-0000000000f1'));
select t.ok('unknown provider id => no row', (select message_id is null and not applied from apply_message_status('sms','SM-NOPE','delivered')));
insert into messages(id,dealer_id,lead_id,contact_id,number_id,channel,direction,author_kind,body,provider_message_id,status) values
 ('00000000-0000-0000-0019-0000000000f2', :d, '00000000-0000-0000-0019-0000000000e1','00000000-0000-0000-0019-0000000000c1',:n1,'sms','outbound','ai','x','SM-OUT-2','sent');
select t.ok('Twilio 21610 on a send => opt-out recorded', (select opted_out from apply_message_status('sms','SM-OUT-2','undelivered','21610',:now)));
select t.ok('...DNC open', exists (select 1 from contact_dnc where contact_id = '00000000-0000-0000-0019-0000000000c1' and channel = 'sms' and cleared_at is null));
insert into messages(id,dealer_id,contact_id,number_id,channel,direction,author_kind,body,provider_message_id,status) values
 ('00000000-0000-0000-0019-0000000000f3', :d, '00000000-0000-0000-0019-0000000000c1','00000000-0000-0000-0019-0000000000d3','email','outbound','ai','x','re_123','sent');
select t.ok('email complaint => email opt-out', (select opted_out from apply_message_status('email','re_123','complained',null,:now)));
select t.ok('...email DNC open', exists (select 1 from contact_dnc where contact_id = '00000000-0000-0000-0019-0000000000c1' and channel = 'email' and cleared_at is null));

-- ======================= E. WhatsApp templates =======================
select t.eq('pull sync upserts', upsert_message_templates('00000000-0000-0000-0019-0000000000d2', '[{"id":"t1","name":"price_drop_v1","language":"en_US","category":"MARKETING","status":"APPROVED","body_text":"Hi {{1}}, {{2}} here: the {{3}} is now {{4}}. Reply STOP to opt out.","param_count":4},
  {"id":"t2","name":"checkin_v1","language":"en_US","category":"UTILITY","status":"APPROVED","body_text":"Hi {{1}}, {{2}} checking in. Reply anytime.","param_count":2}]'::jsonb, :now), 2);
update message_templates set salesos_use = 'price_drop' where name = 'price_drop_v1';
select t.eq('marketing use picks a MARKETING template', (select name from pick_whatsapp_template('00000000-0000-0000-0019-0000000000d2', 'price_drop', 'marketing')), 'price_drop_v1');
select t.eq('conversational use picks UTILITY', (select name from pick_whatsapp_template('00000000-0000-0000-0019-0000000000d2', 'reengage', 'conversational')), 'checkin_v1');
select t.eq('push update by WABA id', apply_template_status('WABA-19', 't1', 'price_drop_v1', 'en_US', 'rejected', 'INVALID_FORMAT', :now), 1);
select t.ok('rejected with reason', (select status = 'REJECTED' and rejected_reason = 'INVALID_FORMAT' from message_templates where name = 'price_drop_v1'));
select t.ok('rejected template is never picked', not exists (select 1 from pick_whatsapp_template('00000000-0000-0000-0019-0000000000d2', 'price_drop', 'marketing')));
select t.eq('other WABA cannot touch it', apply_template_status('WABA-OTHER', 't2', 'checkin_v1', 'en_US', 'PAUSED', null, :now), 0);
select upsert_message_templates('00000000-0000-0000-0019-0000000000d2', '[{"id":"t2","name":"checkin_v1","language":"en_US","category":"UTILITY","status":"APPROVED","body_text":"Hi {{1}}","param_count":1}]'::jsonb, :now);
select t.eq('missing from the pull => DELETED', (select status from message_templates where name = 'price_drop_v1'), 'DELETED');
select t.eq('list numbers for the hourly sync', (select waba_id from list_template_numbers() where number_id = '00000000-0000-0000-0019-0000000000d2'), 'WABA-19');

-- ======================= F. webhook event log =======================
create temp table e1 as select * from log_webhook_event('twilio', 'SM-EV-1', 'inbound', '{"a":1}', :now);
select t.ok('first receipt is new', (select not duplicate from e1));
select t.ok('retry while processing is a duplicate', (select duplicate from log_webhook_event('twilio', 'SM-EV-1', 'inbound', '{}', :now + interval '30 seconds')));
select finish_webhook_event((select event_id from e1), 'failed', 'boom', null, :now);
select t.ok('a failed event is reprocessed on retry', (select not duplicate from log_webhook_event('twilio', 'SM-EV-1', 'inbound', '{}', :now + interval '1 minute')));
select t.eq('attempt counted', (select attempts from event_log where external_id = 'SM-EV-1'), 2);
select finish_webhook_event((select event_id from e1), 'processed', null, :d, :now);
select t.ok('processed => duplicate forever', (select duplicate from log_webhook_event('twilio', 'SM-EV-1', 'inbound', '{}', :now + interval '1 day')));
select t.ok('same id from another provider is a different event', (select not duplicate from log_webhook_event('resend', 'SM-EV-1', 'email.sent', '{}', :now)));

-- ======================= G. agent lanes + run start =======================
insert into contacts(id,dealer_id,first_name,phone_e164) values ('00000000-0000-0000-0019-0000000000c5', :d, 'Gus', '+15555551905');
insert into consent_events(dealer_id,contact_id,channel,purpose,action,source) values (:d,'00000000-0000-0000-0019-0000000000c5','sms','conversational','grant','web_form');
insert into leads(id,dealer_id,contact_id,stage) values ('00000000-0000-0000-0019-0000000000e5', :d, '00000000-0000-0000-0019-0000000000c5', 'qualifying');
\set l5 '\'00000000-0000-0000-0019-0000000000e5\'::uuid'
select enqueue_agent_job(:l5, null, 0, :now);
create temp table j1 as select * from claim_agent_jobs('w1', 10, :now);
select t.eq('claimed one job', (select count(*)::int from j1 where lead_id = :l5), 1);
select enqueue_agent_job(:l5, null, 0, :now);
select t.eq('lane: a running lead is not claimed again', (select count(*)::int from claim_agent_jobs('w2', 10, :now) where lead_id = :l5), 0);
select t.eq('...the new message waits as one queued job', (select count(*)::int from agent_jobs where lead_id = :l5 and status = 'queued'), 1);
select t.raises('lane: never two running jobs for a lead', $q$update agent_jobs set status = 'running' where lead_id = '00000000-0000-0000-0019-0000000000e5' and status = 'queued'$q$, '%agent_jobs_running_lane_uq%');
select t.eq('run start => run', (select start_agent_run((select id from j1), 2, 'mock', 'agent-v1', :now)->>'outcome'), 'run');
select t.ok('run row created and linked', (select run_id is not null from agent_jobs where id = (select id from j1)));
select t.eq('retry with a newer queued job => superseded', finish_agent_job((select id from j1), 'retry', 'model 503', :now), 'skipped');
create temp table j2 as select * from claim_agent_jobs('w1', 10, :now + interval '1 second');
select t.eq('the queued job now runs', (select count(*)::int from j2 where lead_id = :l5), 1);
select t.eq('retry => back to queue with 1 min backoff', finish_agent_job((select id from j2), 'retry', 'model 503', :now), 'queued');
select t.eq('backoff', (select not_before from agent_jobs where id = (select id from j2)), :now + interval '1 minute');
select claim_agent_jobs('w1', 10, :now + interval '2 minutes');
select finish_agent_job((select id from j2), 'retry', 'model 503', :now + interval '2 minutes');
select claim_agent_jobs('w1', 10, :now + interval '10 minutes');
select t.eq('third failure => dead', finish_agent_job((select id from j2), 'retry', 'model 503', :now + interval '10 minutes'), 'dead');
select t.ok('...and a person gets the lead', exists (select 1 from agent_inbox_items where lead_id = :l5 and kind = 'handoff' and status = 'open'));
update agent_inbox_items set status = 'resolved' where lead_id = :l5;
-- stale running job is reclaimed
select enqueue_agent_job(:l5, null, 0, :now);
select claim_agent_jobs('dead-worker', 10, :now);
select t.eq('a job stuck running > 5 min is reclaimed', (select count(*)::int from claim_agent_jobs('w3', 10, :now + interval '6 minutes') where lead_id = :l5), 1);
select t.eq('...by the new worker', (select locked_by from agent_jobs where lead_id = :l5 and status = 'running'), 'w3');
-- outcomes
update leads set force_human = true where id = :l5;
select t.eq('lead owned by a person => skipped_human', (select start_agent_run((select id from agent_jobs where lead_id = :l5 and status = 'running'), 2, 'mock', 'v', :now)->>'outcome'), 'skipped_human');
update leads set force_human = false where id = :l5;
insert into agent_runs(dealer_id, trigger, status, started_at) select :d, 'inbound_message', 'failed', :now - interval '1 minute' from generate_series(1,5);
select t.eq('5 failed runs in 10 min => breaker_open', (select start_agent_run((select id from agent_jobs where lead_id = :l5 and status = 'running'), 2, 'mock', 'v', :now)->>'outcome'), 'breaker_open');
select t.ok('breaker escalates to the inbox', exists (select 1 from agent_inbox_items where lead_id = :l5 and kind = 'handoff' and status = 'open' and payload->>'reason' = 'circuit_breaker'));
delete from agent_runs where dealer_id = :d and status = 'failed';
update ai_budgets set monthly_cap_cents = 0, spent_cents = 0, period_start = date_trunc('month', :now)::date where dealer_id = :d;
select t.eq('budget used up => budget_blocked', (select start_agent_run((select id from agent_jobs where lead_id = :l5 and status = 'running'), 2, 'mock', 'v', :now)->>'outcome'), 'budget_blocked');
select t.ok('budget block writes a run row and an inbox item', exists (select 1 from agent_runs where lead_id = :l5 and status = 'budget_blocked') and exists (select 1 from agent_inbox_items where lead_id = :l5 and kind = 'budget_blocked'));
update ai_budgets set monthly_cap_cents = 5000 where dealer_id = :d;
create temp table rr as select start_agent_run((select id from agent_jobs where lead_id = :l5 and status = 'running'), 3, 'mock', 'v', :now) j;
select finish_agent_run(((select j from rr)->>'run_id')::uuid, 'completed', 3, 1000, 200, 1.25, 3, null, :now);
select t.eq('budget settled to the real cost', (select spent_cents from ai_budgets where dealer_id = :d), 1.2500);
select finish_agent_run(((select j from rr)->>'run_id')::uuid, 'completed', 3, 1000, 200, 9, 3, null, :now);
select t.eq('finishing twice is a no-op', (select spent_cents from ai_budgets where dealer_id = :d), 1.2500);

-- ======================= H. agent tool RPCs =======================
insert into vehicles(id,dealer_id,vin,year,make,model,price_cents,status) values
 ('00000000-0000-0000-0019-000000000091', :d, '3TMCZ5AN1PM000001', 2023, 'Toyota', 'Tacoma', 3600000, 'available'),
 ('00000000-0000-0000-0019-000000000092', :d, '3TMCZ5AN1PM000002', 2023, 'Toyota', 'Tacoma', 3400000, 'sold');
select t.eq('browse shows only available/in_transit', (select count(*)::int from agent_search_inventory(:d, '{"model":"tacoma"}')), 1);
select t.eq('a VIN lookup reveals sold (so the agent never says it is in stock)', (select status from agent_search_inventory(:d, '{"vin":"3TMCZ5AN1PM000002"}')), 'sold');
select t.eq('other dealers see nothing', (select count(*)::int from agent_search_inventory('00000000-0000-0000-0019-0000000000a2', '{"model":"tacoma"}')), 0);
\set run '((select j from rr)->>\'run_id\')::uuid'
select t.eq('test drive at 8pm store time => unavailable', (select agent_book_test_drive(:run, '3TMCZ5AN1PM000001', '2026-03-11 20:00:00-04', 30, null, :now)->>'status'), 'unavailable');
select t.eq('sold vehicle => unavailable', (select agent_book_test_drive(:run, '3TMCZ5AN1PM000002', '2026-03-11 11:00:00-04', 30, null, :now)->>'status'), 'unavailable');
select t.eq('valid slot => requested (never confirmed by the AI)', (select agent_book_test_drive(:run, '3TMCZ5AN1PM000001', '2026-03-11 11:00:00-04', 30, null, :now)->>'status'), 'requested');
select t.eq('appointment is requested', (select status from appointments where lead_id = :l5), 'requested');
create temp table pq as select create_prequal_link(:run, '{"term_months":60}', :now) j;
select t.ok('prequal token stored only as a hash', (select token_hash = encode(sha256(convert_to((select j->>'token' from pq), 'UTF8')), 'hex') and expires_at = :now + interval '72 hours' from prequal_links where lead_id = :l5));
create temp table fu as select agent_schedule_followup(:run, :now + interval '1 day', 'send trim comparison', 'I will send the comparison tomorrow') id;
select t.ok('follow-up promise recorded', (select kind = 'agent_promise' and created_by_run_id = :run from followups where id = (select id from fu)));
create temp table ho as select agent_handoff(:run, 'customer_requested', 'Customer wants to talk to Mike about trade.', 'urgent') id;
select t.ok('handoff sets force_human and opens an urgent item', (select force_human from leads where id = :l5) and (select priority = 1 from agent_inbox_items where id = (select id from ho)));
select t.ok('handoff twice returns the open item', agent_handoff(:run, 'customer_requested', 'again', 'urgent') = (select id from ho));

-- ======================= I. rep approval =======================
update leads set force_human = false where id = :l5;
create temp table dr as select agent_record_draft(jsonb_build_object('dealer_id', :d, 'lead_id', :l5, 'contact_id', '00000000-0000-0000-0019-0000000000c5', 'channel', 'sms',
  'number_id', :n1, 'body_ai', 'The 2023 Tacoma is available at $36,000. Want to see it Saturday?', 'status', 'awaiting_review', 'expected_context_version', 0)) id;
select t.raises('non-member cannot approve', $q$select approve_draft((select id from dr), null, '00000000-0000-0000-0019-0000000000b2')$q$, '%forbidden%');
select t.raises('empty edit rejected', $q$select approve_draft((select id from dr), '   ', '00000000-0000-0000-0019-0000000000b1')$q$, '%empty body%');
select approve_draft((select id from dr), 'The 2023 Tacoma is available at $36,000. Want to see it Saturday at 10?', '00000000-0000-0000-0019-0000000000b1', :now);
select t.ok('approved => held, released now, actor human, edit kept', (select status = 'held' and release_at = :now and actor = 'human' and approved_by = '00000000-0000-0000-0019-0000000000b1' and body_edited ~ 'at 10' from outbound_drafts where id = (select id from dr)));
select t.ok('approval re-bases on the thread the rep read', (select expected_context_version = (select context_version from leads where id = :l5) from outbound_drafts where id = (select id from dr)));
select t.eq('sweeper sees it as approved', (select sweeper_release_facts((select id from dr))->>'approved'), 'true');
update outbound_drafts set status = 'sent' where id = (select id from dr);
select t.raises('a sent draft cannot be approved again', $q$select approve_draft((select id from dr), null, '00000000-0000-0000-0019-0000000000b1')$q$, '%cannot be approved%');
select t.raises('a sent draft cannot be discarded', $q$select discard_draft((select id from dr), '00000000-0000-0000-0019-0000000000b1')$q$, '%too late%');
-- threaded finalize
create temp table dr2 as select agent_record_draft(jsonb_build_object('dealer_id', :d, 'lead_id', :l5, 'contact_id', '00000000-0000-0000-0019-0000000000c5', 'channel', 'sms', 'number_id', :n1, 'body_ai', 'ok', 'status', 'sending')) id;
select finalize_draft_send((select id from dr2), true, 'SM-FIN-1', null, 'ok', :now);
select t.ok('finalize threads the outbound message into the conversation', (select conversation_id is not null and status = 'sent' from messages where provider_message_id = 'SM-FIN-1'));
create temp table dr3 as select agent_record_draft(jsonb_build_object('dealer_id', :d, 'lead_id', :l5, 'contact_id', '00000000-0000-0000-0019-0000000000c5', 'channel', 'sms', 'number_id', :n1, 'body_ai', 'ok', 'status', 'sending')) id;
select finalize_draft_send((select id from dr3), false, null, 'provider_not_configured', 'ok', :now);
select t.ok('a failed send opens a send_failed item', exists (select 1 from agent_inbox_items where lead_id = :l5 and kind = 'send_failed' and status = 'open'));

-- ======================= J. one-click unsubscribe =======================
insert into contacts(id,dealer_id,first_name,email) values ('00000000-0000-0000-0019-0000000000c6', :d, 'Una', 'una@example.com');
create temp table ut as select create_unsubscribe_token(:d, '00000000-0000-0000-0019-0000000000c6', 'email') tok;
select t.ok('token stored hashed only', not exists (select 1 from unsubscribe_tokens where token_hash = (select tok from ut)) and exists (select 1 from unsubscribe_tokens where contact_id = '00000000-0000-0000-0019-0000000000c6'));
select t.eq('one-click POST unsubscribes', (select redeem_unsubscribe_token((select tok from ut), 'one_click_post', :now)->>'ok'), 'true');
select t.ok('email DNC open', exists (select 1 from contact_dnc where contact_id = '00000000-0000-0000-0019-0000000000c6' and channel = 'email' and cleared_at is null));
select t.eq('second click is a no-op', (select redeem_unsubscribe_token((select tok from ut), 'web_form', :now)->>'already'), 'true');
select t.eq('exactly one revoke event', (select count(*)::int from consent_events where contact_id = '00000000-0000-0000-0019-0000000000c6' and action = 'revoke'), 1);
select t.eq('unknown token', (select redeem_unsubscribe_token('deadbeefdeadbeefdeadbeefdeadbeef')->>'error'), 'unknown_token');
select t.raises('cannot mint a token for another dealer''s contact', $q$select create_unsubscribe_token('00000000-0000-0000-0019-0000000000a2', '00000000-0000-0000-0019-0000000000c6')$q$, '%contact not found%');

-- ======================= K. classification queue =======================
select t.ok('STOP removed the lead''s pending classification', not exists (select 1 from classify_queue where message_id = (select message_id from i2)));
create temp table g1 as select * from ingest_inbound_message(:n1, '+15555551905', 'can I drive it saturday', 'SM-CQ-1', :now);
select apply_inbound_keyword((select message_id from g1), 'none', 'channel', null, false, false, :now);
create temp table cq as select * from claim_classification_jobs(20, :now + interval '1 minute');
select t.ok('claims queued messages with lead context', exists (select 1 from cq where message_id = (select message_id from g1) and context_version is not null and lead_stage = 'qualifying'));
select t.eq('a claimed job is not claimed twice', (select count(*)::int from claim_classification_jobs(20, :now + interval '2 minutes') where message_id = (select message_id from g1)), 0);
select finish_classification_job((select message_id from g1), false, 'upstream 503', :now);
select t.ok('failure backs off', (select not_before > :now and locked_at is null from classify_queue where message_id = (select message_id from g1)));
select finish_classification_job((select message_id from g1), true, null, :now);
select t.ok('success removes it', not exists (select 1 from classify_queue where message_id = (select message_id from g1)));

-- ======================= L. prune =======================
insert into event_log(provider, external_id, event_type, received_at, status) values ('twilio', 'OLD-1', 'inbound', :now - interval '31 days', 'processed');
select prune_runtime(:now);
select t.ok('event_log pruned after 30 days (raw payloads are PII)', not exists (select 1 from event_log where external_id = 'OLD-1') and exists (select 1 from event_log where external_id = 'SM-EV-1'));

-- ======================= M. RLS + grants =======================
set role anon;
select t.raises('anon cannot read event_log', $q$select * from event_log$q$, '%permission denied%');
reset role;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0019-0000000000b1"}', false);
set role authenticated;
select t.ok('member sees own conversations', (select count(*) from conversations) > 0);
select t.eq('...only their dealer''s', (select count(*)::int from conversations where dealer_id <> '00000000-0000-0000-0019-0000000000a1'), 0);
select t.ok('member sees templates', (select count(*) from message_templates) > 0);
select t.raises('member cannot read send_attempts', $q$select * from send_attempts$q$, '%permission denied%');
select t.raises('member cannot read unsubscribe token hashes', $q$select * from unsubscribe_tokens$q$, '%permission denied%');
select t.raises('member cannot claim sends', $q$select * from claim_send_attempt('00000000-0000-0000-0019-0000000000a1', 'x', 'twilio')$q$, '%permission denied%');
select t.raises('member cannot ingest messages', $q$select * from ingest_inbound_message('00000000-0000-0000-0019-0000000000d1', '+15555551999', 'x', 'SM-RLS')$q$, '%permission denied%');
select t.raises('member cannot call can_send directly', $q$select can_send('00000000-0000-0000-0019-0000000000a1','00000000-0000-0000-0019-0000000000c1','sms','conversational','reply','00000000-0000-0000-0019-0000000000d1')$q$, '%permission denied%');
create temp table dr4 as select 1;
reset role;
create temp table dr5 as select agent_record_draft(jsonb_build_object('dealer_id', :d, 'lead_id', :l5, 'contact_id', '00000000-0000-0000-0019-0000000000c5', 'channel', 'sms', 'number_id', :n1, 'body_ai', 'Sure, see you then.', 'status', 'awaiting_review')) id;
grant select on dr5 to authenticated;
set role authenticated;
select t.eq('a signed-in rep can approve (auth.uid())', (select approve_draft((select id from dr5))->>'status'), 'held');
reset role;
select set_config('request.jwt.claims', '', false);

-- ======================= N. cron =======================
do $$ begin
  if to_regclass('cron.job') is null then raise notice 'ok   [cron skipped: pg_cron unavailable]'; return; end if;
  perform t.eq('agent runner every 15 s', (select schedule from cron.job where jobname = 'salesos-agent-runner'), '15 seconds');
  perform t.eq('classifier every 30 s', (select schedule from cron.job where jobname = 'salesos-classify'), '30 seconds');
  perform t.eq('template sync hourly', (select schedule from cron.job where jobname = 'salesos-template-sync'), '17 * * * *');
  perform t.eq('runtime prune nightly', (select schedule from cron.job where jobname = 'salesos-runtime-prune'), '45 3 * * *');
  perform t.eq('12 SalesOS jobs in total (11 + keyword-reply outbox)', (select count(*)::int from cron.job where jobname like 'salesos-%'), 12);
end $$;
select kick_agent_runner(), kick_classify_worker(), kick_template_sync();
-- ======================= O. STOP cycle uses DB time (regression: worker clock behind the DB) =======================
insert into contacts(id,dealer_id,phone_e164) values ('00000000-0000-0000-0000-0000000c1001', (select dealer_id from channel_numbers where id = :n1), '+15555551777');
insert into consent_events(dealer_id,contact_id,channel,purpose,action,source)
  select dealer_id, '00000000-0000-0000-0000-0000000c1001', 'sms', 'conversational', 'grant', 'web_form' from channel_numbers where id = :n1;
create temp table sk1 as select * from ingest_inbound_message(:n1, '+15555551777', 'STOP', 'SM-SKEW-1', now() - interval '2 minutes');
create temp table sk1k as select * from apply_inbound_keyword((select message_id from sk1), 'stop', 'channel', 'STOP', false, false, now() - interval '2 minutes');
select t.eq('skew: first STOP claims a confirmation', (select reply_kind from sk1k), 'stop');
create temp table sk2 as select * from ingest_inbound_message(:n1, '+15555551777', 'stop', 'SM-SKEW-2', now() - interval '1 minute');
create temp table sk2k as select * from apply_inbound_keyword((select message_id from sk2), 'stop', 'channel', 'stop', false, false, now() - interval '1 minute');
select t.ok('skew: second STOP gets no confirmation even with a lagging p_now', (select reply_kind is null from sk2k));
\echo RUNTIME TESTS PASSED
