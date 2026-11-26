\set ON_ERROR_STOP 1
-- Feature 6: plan generation (6 triggers), consent-scoped price-drop fan-out, claim/outcome state machine, stops
\set d '\'00000000-0000-0000-0016-0000000000a1\'::uuid'
\set now '\'2026-03-10 15:00:00+00\'::timestamptz'
insert into dealers(id,name,timezone) values (:d,'Follow Motors','America/New_York');
insert into channel_numbers(id,dealer_id,channel,address,activated_at) values
 ('00000000-0000-0000-0016-0000000000a8', :d, 'sms', '+15555516999', '2026-01-01'),
 ('00000000-0000-0000-0016-0000000000a9', :d, 'email', 'sales@follow.test', '2026-01-01');
insert into contacts(id,dealer_id,first_name,phone_e164,email) values
 ('00000000-0000-0000-0016-0000000000c1', :d, 'Ann', '+15555516001', null),
 ('00000000-0000-0000-0016-0000000000c2', :d, 'Ben', '+15555516002', null),
 ('00000000-0000-0000-0016-0000000000c3', :d, 'Cat', '+15555516003', null),
 ('00000000-0000-0000-0016-0000000000c4', :d, 'Dan', null, 'dan@x.test'),
 ('00000000-0000-0000-0016-0000000000c5', :d, 'Eve', '+15555516005', null),
 ('00000000-0000-0000-0016-0000000000c6', :d, 'Fay', '+15555516006', null);
insert into consent_events(dealer_id,contact_id,channel,purpose,action,source,disclosure_text_version) values
 (:d,'00000000-0000-0000-0016-0000000000c1','sms','marketing','grant','web_form','tcpa-v3'),
 (:d,'00000000-0000-0000-0016-0000000000c3','sms','marketing','grant','web_form','tcpa-v3'),
 (:d,'00000000-0000-0000-0016-0000000000c5','sms','marketing','grant','web_form','tcpa-v3'),
 (:d,'00000000-0000-0000-0016-0000000000c4','email','conversational','grant','web_form',null);
select record_opt_out(:d,'00000000-0000-0000-0016-0000000000c3',null,'sms_keyword','{}','STOP');    -- Cat: all-channel DNC
insert into leads(id,dealer_id,contact_id,stage,lease_end_on,force_human) values
 ('00000000-0000-0000-0016-0000000000e1', :d,'00000000-0000-0000-0016-0000000000c1','qualifying',null,false),
 ('00000000-0000-0000-0016-0000000000e2', :d,'00000000-0000-0000-0016-0000000000c2','qualified',null,false),
 ('00000000-0000-0000-0016-0000000000e3', :d,'00000000-0000-0000-0016-0000000000c3','qualifying',null,false),
 ('00000000-0000-0000-0016-0000000000e5', :d,'00000000-0000-0000-0016-0000000000c5','new','2026-04-24',false),
 ('00000000-0000-0000-0016-0000000000e6', :d,'00000000-0000-0000-0016-0000000000c6','test_drive',null,true),
 ('00000000-0000-0000-0016-0000000000e7', :d,'00000000-0000-0000-0016-0000000000c4','contacted',null,false);
update leads set last_inbound_at = :now - interval '5 days', last_outbound_at = :now - interval '3 days' where id = '00000000-0000-0000-0016-0000000000e2';  -- Ben: stalled
update leads set last_inbound_at = :now - interval '2 days', last_outbound_at = :now - interval '10 hours' where id = '00000000-0000-0000-0016-0000000000e7'; -- Dan: too soon
insert into followups(dealer_id,lead_id,kind,due_at,reason,promised_text) values (:d,'00000000-0000-0000-0016-0000000000e1','agent_promise', :now - interval '2 minutes','check incoming Accords','I''ll check Tuesday');
insert into appointments(dealer_id,lead_id,kind,starts_at,status) values (:d,'00000000-0000-0000-0016-0000000000e6','test_drive', :now - interval '150 minutes','confirmed');
insert into customer_vehicles(dealer_id,contact_id,lead_id,year,make,model,next_service_due_on) values (:d,'00000000-0000-0000-0016-0000000000c5','00000000-0000-0000-0016-0000000000e5',2021,'Honda','CR-V','2026-03-17');
insert into vehicles(id,dealer_id,vin,year,make,model,price_cents,status) values ('00000000-0000-0000-0016-00000000aa01', :d,'1HGCV1F30LA160001',2022,'Honda','Accord',3000000,'available');
insert into lead_vehicle_views(dealer_id,lead_id,vehicle_id,viewed_at) values
 (:d,'00000000-0000-0000-0016-0000000000e1','00000000-0000-0000-0016-00000000aa01', :now - interval '2 days'),   -- consent
 (:d,'00000000-0000-0000-0016-0000000000e2','00000000-0000-0000-0016-00000000aa01', :now - interval '2 days'),   -- no consent
 (:d,'00000000-0000-0000-0016-0000000000e3','00000000-0000-0000-0016-00000000aa01', :now - interval '2 days');   -- DNC
update vehicles set price_cents = 2800000 where id = '00000000-0000-0000-0016-00000000aa01';
select t.eq('price drop recorded as a vehicle event', (select count(*) from vehicle_events where vehicle_id = '00000000-0000-0000-0016-00000000aa01' and kind = 'price_drop')::int, 1);
select t.eq('...and fed to the briefing table', (select count(*) from vehicle_price_events where vehicle_id = '00000000-0000-0000-0016-00000000aa01')::int, 1);

-- generation
do $$ declare v jsonb; begin
  v := generate_followup_plans('2026-03-10 15:00:00+00');
  perform t.eq('promised plan from the agent''s promise', (v->>'promised')::int, 1);
  perform t.eq('stalled: Ben only (Dan spoke 10h ago)', (v->>'stalled')::int, 1);
  perform t.eq('no-show plan', (v->>'test_drive_noshow')::int, 1);
  perform t.eq('price drop fans out ONLY to the consenting viewer', (v->>'price_drop')::int, 1);
  perform t.eq('service due within 14 days', (v->>'service_due')::int, 1);
  perform t.eq('lease end: one touch', (v->>'lease_end')::int, 1);
end $$;
select t.eq('price-drop plan went to Ann', (select lead_id::text from followup_plans where trigger_kind = 'price_drop' and dealer_id = :d), '00000000-0000-0000-0016-0000000000e1');
select t.eq('price-drop plan is marketing on the consented channel', (select purpose::text || '/' || channel from followup_plans where trigger_kind = 'price_drop' and dealer_id = :d), 'marketing/sms');
select t.ok('event marked fanned out with its count', (select fanned_out_at is not null and fanout_count = 1 from vehicle_events where vehicle_id = '00000000-0000-0000-0016-00000000aa01' and kind = 'price_drop'));
select t.eq('lease touch is the 60-day mark (45 days left)', (select context->>'mark_days' from followup_plans where trigger_kind = 'lease_end' and dealer_id = :d), '60');
select t.eq('promise marked due', (select status from followups where lead_id = '00000000-0000-0000-0016-0000000000e1'), 'due');
select t.eq('re-running the generator is idempotent', (select sum(value::int) from jsonb_each_text(generate_followup_plans('2026-03-10 15:00:00+00')))::int, 0);

-- claim: one per contact, force_human skipped, no double claim
do $$ declare n int; begin
  select count(*) into n from claim_due_followups(50, '2026-03-10 15:00:00+00') where dealer_id = '00000000-0000-0000-0016-0000000000a1';
  perform t.eq('claims Ann, Ben, Eve (one plan each; Fay is human-owned)', n, 3);
  select count(*) into n from claim_due_followups(50, '2026-03-10 15:00:30+00') where dealer_id = '00000000-0000-0000-0016-0000000000a1';
  perform t.eq('no double claim, and no second plan for a contact mid-flight', n, 0);
end $$;
select t.eq('Ann''s promise claimed before her price drop (earliest due)', (select trigger_kind::text from followup_plans where status = 'claimed' and contact_id = '00000000-0000-0000-0016-0000000000c1'), 'promised');
select t.eq('human-owned no-show stays scheduled', (select status::text from followup_plans where trigger_kind = 'test_drive_noshow' and dealer_id = :d), 'scheduled');

-- outcomes
select t.eq('sent', record_followup_outcome((select id from followup_plans where status = 'claimed' and contact_id = '00000000-0000-0000-0016-0000000000c1'), 'sent', 'ok', null, null, :now)::text, 'sent');
select t.eq('sent promise closes the followup', (select status from followups where lead_id = '00000000-0000-0000-0016-0000000000e1'), 'done');
select t.eq('quiet hours => postponed to not_before, not dropped',
  record_followup_outcome((select id from followup_plans where status = 'claimed' and contact_id = '00000000-0000-0000-0016-0000000000c2'), 'delayed', 'quiet_hours', '2026-03-11 12:00:00+00', null, :now)::text, 'postponed');
select t.ok('postponed plan carries the new due time and count', (select due_at = '2026-03-11 12:00:00+00' and postponed_count = 1 and attempts = 0 from followup_plans where contact_id = '00000000-0000-0000-0016-0000000000c2' and trigger_kind = 'stalled'));
\set evep '(select id from followup_plans where status = \'claimed\' and contact_id = \'00000000-0000-0000-0016-0000000000c5\')'
select t.eq('content veto => retry with backoff', record_followup_outcome(:evep, 'retry', 'unverified_price', null, null, :now)::text, 'postponed');
select t.raises('outcome on an unclaimed plan is refused', $q$select record_followup_outcome((select id from followup_plans where trigger_kind = 'test_drive_noshow' and dealer_id = '00000000-0000-0000-0016-0000000000a1'), 'sent')$q$, '%not claimed%');

do $$ declare n int; begin
  select count(*) into n from claim_due_followups(50, '2026-03-10 15:01:00+00') where dealer_id = '00000000-0000-0000-0016-0000000000a1';
  perform t.eq('Ann''s price drop waits: min gap after a sent follow-up; Eve''s other plan goes', n, 1);
end $$;
select t.eq('no consent => cancelled with the reason', record_followup_outcome(:evep, 'stop', 'no_consent', null, null, :now)::text, 'cancelled');
-- attempt cap: Eve's remaining plan (attempts 1, due +1h)
do $$ declare p uuid; begin
  select id into p from followup_plans where contact_id = '00000000-0000-0000-0016-0000000000c5' and status = 'postponed';
  perform claim_due_followups(50, '2026-03-10 16:01:00+00');
  perform t.eq('2nd failure', record_followup_outcome(p, 'retry', 'provider_error', null, null, '2026-03-10 16:01:00+00')::text, 'postponed');
  perform t.eq('backoff doubles (2h)', (select due_at from followup_plans where id = p), '2026-03-10 18:01:00+00'::timestamptz);
  perform claim_due_followups(50, '2026-03-10 18:02:00+00');
  perform t.eq('3rd failure => exhausted (max_attempts 3)', record_followup_outcome(p, 'retry', 'provider_error', null, null, '2026-03-10 18:02:00+00')::text, 'exhausted');
  perform t.ok('exhausted plan lands in the rep inbox', exists (select 1 from agent_inbox_items where lead_id = '00000000-0000-0000-0016-0000000000e5' and kind = 'needs_review' and status = 'open'));
end $$;
-- postponing past the expiry window
do $$ declare p uuid; begin
  select id into p from followup_plans where contact_id = '00000000-0000-0000-0016-0000000000c2' and trigger_kind = 'stalled';
  perform claim_due_followups(50, '2026-03-11 12:00:00+00');
  perform t.eq('postponed beyond expires_at => exhausted, never silently dropped', record_followup_outcome(p, 'delayed', 'daily_cap', '2026-03-20 12:00:00+00', null, '2026-03-11 12:00:00+00')::text, 'exhausted');
  perform t.eq('reason recorded', (select stop_reason from followup_plans where id = p), 'postpone_window_passed');
end $$;
insert into followup_plans(dealer_id,lead_id,contact_id,trigger_kind,purpose,due_at,expires_at,dedupe_key) values
 (:d,'00000000-0000-0000-0016-0000000000e7','00000000-0000-0000-0016-0000000000c4','stalled','conversational', :now - interval '9 days', :now - interval '1 day','test:expired');
do $$ begin perform claim_due_followups(50, '2026-03-10 15:05:00+00'); end $$;
select t.eq('expired plans are exhausted at claim time', (select status::text || ':' || stop_reason from followup_plans where dedupe_key = 'test:expired'), 'exhausted:expired');

-- stop conditions
insert into followup_plans(dealer_id,lead_id,contact_id,trigger_kind,purpose,due_at,expires_at,dedupe_key) values
 (:d,'00000000-0000-0000-0016-0000000000e7','00000000-0000-0000-0016-0000000000c4','promised','conversational', :now + interval '1 day', :now + interval '9 days','test:reply');
insert into messages(dealer_id,lead_id,contact_id,channel,direction,body) values (:d,'00000000-0000-0000-0016-0000000000e7','00000000-0000-0000-0016-0000000000c4','email','inbound','thanks, will call you');
select t.eq('any inbound stops the plan', (select status::text || ':' || stop_reason from followup_plans where dedupe_key = 'test:reply'), 'cancelled:customer_replied');
insert into followup_plans(dealer_id,lead_id,contact_id,trigger_kind,purpose,due_at,expires_at,dedupe_key) values
 (:d,'00000000-0000-0000-0016-0000000000e5','00000000-0000-0000-0016-0000000000c5','lease_end','marketing', :now + interval '1 day', :now + interval '9 days','test:mkt'),
 (:d,'00000000-0000-0000-0016-0000000000e5','00000000-0000-0000-0016-0000000000c5','promised','conversational', :now + interval '1 day', :now + interval '9 days','test:conv');
insert into consent_events(dealer_id,contact_id,channel,purpose,action,source) values (:d,'00000000-0000-0000-0016-0000000000c5','sms','marketing','revoke','inbound_message');
select t.eq('revoking marketing cancels marketing plans', (select status::text from followup_plans where dedupe_key = 'test:mkt'), 'cancelled');
select t.eq('...but not conversational ones', (select status::text from followup_plans where dedupe_key = 'test:conv'), 'scheduled');
select record_opt_out(:d,'00000000-0000-0000-0016-0000000000c5','sms','sms_keyword','{}','STOP');
select t.eq('STOP cancels everything for the contact', (select status::text || ':' || stop_reason from followup_plans where dedupe_key = 'test:conv'), 'cancelled:opted_out');
update vehicles set status = 'sold' where id = '00000000-0000-0000-0016-00000000aa01';
select t.eq('sold vehicle cancels its price-drop plan', (select status::text || ':' || stop_reason from followup_plans where trigger_kind = 'price_drop' and dealer_id = :d), 'cancelled:vehicle_sold');
update leads set stage = 'won' where id = '00000000-0000-0000-0016-0000000000e6';
select t.eq('won lead cancels its plans', (select status::text || ':' || stop_reason from followup_plans where trigger_kind = 'test_drive_noshow' and dealer_id = :d), 'cancelled:lead_closed_won');
update dealer_settings set followup_triggers = '{promised}' where dealer_id = :d;
update leads set lease_end_on = '2026-04-01' where id = '00000000-0000-0000-0016-0000000000e1';
select t.eq('disabled triggers generate nothing', ((generate_followup_plans('2026-03-12 15:00:00+00'))->>'lease_end')::int, 0);

-- routing and gate context
select t.eq('route: SMS for a phone contact', (select channel::text from pick_send_route(:d,'00000000-0000-0000-0016-0000000000c1',null)), 'sms');
select t.eq('route: preferred WhatsApp without a WA number falls back to SMS', (select channel::text from pick_send_route(:d,'00000000-0000-0000-0016-0000000000c1','whatsapp')), 'sms');
select t.eq('route: email-only contact', (select channel::text from pick_send_route(:d,'00000000-0000-0000-0016-0000000000c4',null)), 'email');
select t.eq('route: all-channel DNC => unreachable', (select count(*) from pick_send_route(:d,'00000000-0000-0000-0016-0000000000c3',null))::int, 0);
select t.eq('route: SMS opt-out, no email => unreachable', (select count(*) from pick_send_route(:d,'00000000-0000-0000-0016-0000000000c5',null))::int, 0);
do $$ declare g jsonb; begin
  g := get_gate_context('00000000-0000-0000-0016-0000000000a1','00000000-0000-0000-0016-0000000000c4','00000000-0000-0000-0016-0000000000e7','email');
  perform t.eq('gate context: dealer name', g->>'dealer_name', 'Follow Motors');
  perform t.eq('gate context: latest inbound text for the opt-out gate', g->'latest_inbound'->>'body', 'thanks, will call you');
  perform t.eq('gate context: settings carried', (g->'settings'->>'rep_hold_minutes')::int, 15);
  perform t.eq('gate context: dnc flag', (get_gate_context('00000000-0000-0000-0016-0000000000a1','00000000-0000-0000-0016-0000000000c3',null,'sms')->'contact'->>'dnc_open')::boolean, true);
end $$;

-- sweeper bookkeeping
insert into outbound_drafts(id,dealer_id,lead_id,contact_id,channel,number_id,body_ai,status,kind) values
 ('00000000-0000-0000-0016-0000000000d1', :d,'00000000-0000-0000-0016-0000000000e1','00000000-0000-0000-0016-0000000000c1','sms','00000000-0000-0000-0016-0000000000a8','Following up as promised.','sending','followup'),
 ('00000000-0000-0000-0016-0000000000d2', :d,'00000000-0000-0000-0016-0000000000e1','00000000-0000-0000-0016-0000000000c1','sms','00000000-0000-0000-0016-0000000000a8','Second.','sending','followup');
select t.ok('finalize ok => outbound message row', finalize_draft_send('00000000-0000-0000-0016-0000000000d1', true, 'SM123') is not null);
select t.eq('draft marked sent', (select status from outbound_drafts where id = '00000000-0000-0000-0016-0000000000d1'), 'sent');
select t.ok('lead last_outbound_at updated by the message trigger', (select last_outbound_at > '2026-06-01' from leads where id = '00000000-0000-0000-0016-0000000000e1'));
select finalize_draft_send('00000000-0000-0000-0016-0000000000d2', false, null, 'carrier rejected');
select t.eq('finalize failure => failed with code', (select status || ':' || veto_code from outbound_drafts where id = '00000000-0000-0000-0016-0000000000d2'), 'failed:carrier rejected');
select t.raises('cannot finalize twice', $q$select finalize_draft_send('00000000-0000-0000-0016-0000000000d1', true)$q$, '%not sending%');
select 'FOLLOWUP TESTS PASSED';
