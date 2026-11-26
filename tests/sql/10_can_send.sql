\set ON_ERROR_STOP 1
-- fixtures: NY dealer, FL dealer, contacts, numbers
insert into dealers(id,name,timezone,state_code) values
 ('00000000-0000-0000-0000-0000000000a1','Acme NY','America/New_York','NY'),
 ('00000000-0000-0000-0000-0000000000a2','Beach FL','America/New_York','FL');
insert into contacts(id,dealer_id,first_name,phone_e164,email,timezone,state_code) values
 ('00000000-0000-0000-0000-00000000c001','00000000-0000-0000-0000-0000000000a1','Ann','+15555550101','ann@x.test',null,null),
 ('00000000-0000-0000-0000-00000000c002','00000000-0000-0000-0000-0000000000a1','Bob','+15555550102',null,null,null),
 ('00000000-0000-0000-0000-00000000c003','00000000-0000-0000-0000-0000000000a2','Flo','+15555550103',null,null,'FL'),
 ('00000000-0000-0000-0000-00000000c004','00000000-0000-0000-0000-0000000000a1','NoPhone',null,null,null,null);
insert into channel_numbers(id,dealer_id,channel,address,activated_at) values
 ('00000000-0000-0000-0000-0000000000b1','00000000-0000-0000-0000-0000000000a1','sms','+15555559001','2026-01-01'),
 ('00000000-0000-0000-0000-0000000000b2','00000000-0000-0000-0000-0000000000a1','whatsapp','+15555559002','2026-01-01'),
 ('00000000-0000-0000-0000-0000000000b3','00000000-0000-0000-0000-0000000000a2','sms','+15555559003','2026-01-01');
insert into leads(id,dealer_id,contact_id) values
 ('00000000-0000-0000-0000-00000000e001','00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c001');

\set d1 '\'00000000-0000-0000-0000-0000000000a1\'::uuid'
\set d2 '\'00000000-0000-0000-0000-0000000000a2\'::uuid'
\set ann '\'00000000-0000-0000-0000-00000000c001\'::uuid'
\set bob '\'00000000-0000-0000-0000-00000000c002\'::uuid'
\set flo '\'00000000-0000-0000-0000-00000000c003\'::uuid'
\set nophone '\'00000000-0000-0000-0000-00000000c004\'::uuid'
\set n1 '\'00000000-0000-0000-0000-0000000000b1\'::uuid'
\set n2 '\'00000000-0000-0000-0000-0000000000b2\'::uuid'
\set n3 '\'00000000-0000-0000-0000-0000000000b3\'::uuid'
\set lead1 '\'00000000-0000-0000-0000-00000000e001\'::uuid'
-- 2026-03-10 15:00Z = 11:00 EDT (DST began 2026-03-08)
\set noon '\'2026-03-10 15:00:00+00\'::timestamptz'

do $$ begin
  perform t.eq('settings auto-seeded', (select count(*) from dealer_settings)::int, 2);
  perform t.eq('budget auto-seeded', (select count(*) from ai_budgets)::int, 2);
end $$;

-- 1. no consent => veto
select t.eq('no consent -> veto no_consent', (can_send(:d1,:ann,'sms','conversational','followup',:n1,'hello there friend',null,'ai',false,false,null,:noon)).code, 'no_consent');

-- 2. grant marketing WITHOUT disclosure version => evidence not ok => still veto
insert into consent_events(dealer_id,contact_id,channel,purpose,action,source) values (:d1,:ann,'sms','marketing','grant','web_form');
select t.eq('marketing grant w/o disclosure version is not valid', (can_send(:d1,:ann,'sms','marketing','followup',:n1,'hello there friend',null,'ai',false,false,null,:noon)).code, 'no_consent');

-- 3. proper grant
insert into consent_events(dealer_id,contact_id,channel,purpose,action,source,disclosure_text_version,evidence)
 values (:d1,:ann,'sms','marketing','grant','web_form','tcpa-v3','{"form_url":"https://x.test/f"}');
select t.eq('valid marketing grant -> allow (dry run)', (can_send(:d1,:ann,'sms','marketing','followup',:n1,'hello there friend',null,'ai',false,false,null,:noon)).code, 'ok');
select t.eq('marketing covers conversational', (can_send(:d1,:ann,'sms','conversational','followup',:n1,'second different text here',null,'ai',false,false,null,:noon)).code, 'ok');
select t.eq('grant is per channel (whatsapp has none)', (can_send(:d1,:ann,'whatsapp','marketing','followup',:n2,'hello there friend',null,'ai',false,false,null,:noon)).code, 'no_consent');
select t.eq('cold requires marketing purpose', (can_send(:d1,:ann,'sms','conversational','cold',:n1,'hello there friend',null,'ai',false,false,null,:noon)).code, 'cold_requires_marketing');

-- 4. quiet hours: 02:00Z Mar 11 = 22:00 EDT Mar 10 -> delay until 08:00 EDT = 12:00Z
do $$ declare r send_decision; begin
  r := can_send('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c001','sms','marketing','followup','00000000-0000-0000-0000-0000000000b1','good evening to you',null,'ai',false,false,null,'2026-03-11 02:00:00+00');
  perform t.eq('quiet hours -> delay', r.code, 'quiet_hours');
  perform t.eq('not_before is 08:00 recipient-local', r.not_before, '2026-03-11 12:00:00+00'::timestamptz);
  r := can_send('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c001','sms','marketing','followup','00000000-0000-0000-0000-0000000000b1','good evening to you',null,'ai',false,false,null,'2026-03-10 12:30:00+00'); -- 08:30 EDT
  perform t.eq('08:30 local is inside the window', r.code, 'ok');
  r := can_send('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c001','sms','marketing','followup','00000000-0000-0000-0000-0000000000b1','good evening to you',null,'ai',false,false,null,'2026-03-10 11:59:00+00'); -- 07:59 EDT
  perform t.eq('07:59 local is outside', r.code, 'quiet_hours');
  r := can_send('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c001','sms','marketing','followup','00000000-0000-0000-0000-0000000000b1','good evening to you',null,'ai',false,false,null,'2026-03-11 01:00:00+00'); -- 21:00 EDT exactly
  perform t.eq('21:00 local is outside ([8,21))', r.code, 'quiet_hours');
  -- contact timezone wins over dealer tz: Pacific contact at 15:00Z = 08:00 PDT -> allowed; at 14:59Z = 07:59 -> delay
  update contacts set timezone = 'America/Los_Angeles' where id = '00000000-0000-0000-0000-00000000c001';
  r := can_send('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c001','sms','marketing','followup','00000000-0000-0000-0000-0000000000b1','good evening to you',null,'ai',false,false,null,'2026-03-10 15:00:00+00');
  perform t.eq('contact tz (PDT) 08:00 allowed', r.code, 'ok');
  r := can_send('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c001','sms','marketing','followup','00000000-0000-0000-0000-0000000000b1','good evening to you',null,'ai',false,false,null,'2026-03-10 14:59:00+00');
  perform t.eq('contact tz (PDT) 07:59 delayed', r.code, 'quiet_hours');
  update contacts set timezone = null where id = '00000000-0000-0000-0000-00000000c001';
end $$;

-- 5. state rule: Florida contact 20:30 local is outside (8pm), NY contact 20:30 inside
insert into consent_events(dealer_id,contact_id,channel,purpose,action,source,disclosure_text_version)
 values (:d2,:flo,'sms','marketing','grant','web_form','tcpa-v3');
select t.eq('FL 20:30 local -> delay (FTSA 8pm)', (can_send(:d2,:flo,'sms','marketing','followup',:n3,'florida hello there',null,'ai',false,false,null,'2026-03-11 00:30:00+00')).code, 'quiet_hours');
select t.eq('NY 20:30 local -> ok (federal 9pm)', (can_send(:d1,:ann,'sms','marketing','followup',:n1,'new york hello there',null,'ai',false,false,null,'2026-03-11 00:30:00+00')).code, 'ok');

-- 6. replies: window + no consent needed + quiet hours ignored
insert into messages(dealer_id,lead_id,contact_id,number_id,channel,direction,author_kind,body,created_at)
 values (:d1,:lead1,:bob,:n1,'sms','inbound','contact','is the Accord still there?','2026-03-10 13:00:00+00');
select t.eq('reply within window w/o consent -> ok', (can_send(:d1,:bob,'sms','conversational','reply',:n1,'Let me check that for you.',null,'ai',false,false,null,:noon)).code, 'ok');
do $$ declare r send_decision; begin
  r := can_send('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c002','sms','conversational','reply','00000000-0000-0000-0000-0000000000b1','Let me check that for you.',null,'ai',false,false,null,'2026-03-10 13:30:00+00');
  perform t.eq('reply 09:30 ok', r.code, 'ok');
  r := can_send('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c002','sms','conversational','reply','00000000-0000-0000-0000-0000000000b1','Let me check that for you.',null,'ai',false,false,null,'2026-03-10 13:40:00+00');
  perform t.eq('reply sanity', r.code, 'ok');
  r := can_send('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c002','sms','conversational','reply','00000000-0000-0000-0000-0000000000b1','Let me check that for you.',null,'ai',false,false,null,'2026-03-11 14:30:00+00'); -- 25.5h after inbound
  perform t.eq('sms reply after window closed', r.code, 'reply_window_closed');
  update dealer_settings set reply_window_hours = 72 where dealer_id = '00000000-0000-0000-0000-0000000000a1';
  r := can_send('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c002','sms','conversational','reply','00000000-0000-0000-0000-0000000000b1','Let me check that for you.',null,'ai',false,false,null,'2026-03-11 14:30:00+00');
  perform t.eq('sms window 72h -> ok', r.code, 'ok');
  insert into messages(dealer_id,contact_id,number_id,channel,direction,author_kind,body,created_at)
   values ('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c002','00000000-0000-0000-0000-0000000000b2','whatsapp','inbound','contact','hi','2026-03-10 13:00:00+00');
  r := can_send('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c002','whatsapp','conversational','reply','00000000-0000-0000-0000-0000000000b2','Let me check that for you.',null,'ai',false,false,null,'2026-03-11 14:30:00+00');
  perform t.eq('whatsapp window is capped at 24h even if setting is 72', r.code, 'wa_window_closed');
  perform t.ok('wa_window_closed says template required', (r.details->>'requires_template')::boolean);
  update dealer_settings set reply_window_hours = 24 where dealer_id = '00000000-0000-0000-0000-0000000000a1';
end $$;

-- 7. DNC: STOP wins, staff can't override, contact can re-opt-in
do $$ declare r send_decision; ev uuid; begin
  ev := record_opt_out('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c001','sms','sms_keyword','{"text":"STOP"}');
  r := can_send('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c001','sms','marketing','followup','00000000-0000-0000-0000-0000000000b1','after the stop hello',null,'ai',false,false,null,'2026-03-10 15:00:00+00');
  perform t.eq('STOP -> dnc_active', r.code, 'dnc_active');
  perform t.eq('state revoked', (select status from contact_consent_state where contact_id='00000000-0000-0000-0000-00000000c001' and channel='sms' and purpose='marketing'), 'revoked');
  perform t.raises('staff grant cannot clear DNC',
    $q$insert into consent_events(dealer_id,contact_id,channel,purpose,action,source,disclosure_text_version,evidence) values ('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c001','sms','marketing','grant','staff_entry','v1','{"proof_uri":"x"}')$q$, 'DNC_ACTIVE%');
  perform t.raises('consent_events is append-only (update)', $q$update consent_events set note='x'$q$, '%append-only%');
  perform t.raises('consent_events is append-only (delete)', $q$delete from consent_events$q$, '%append-only%');
  -- email is a different channel: STOP on sms does not kill email unless all-channel
  perform t.eq('sms STOP leaves email channel judged by its own consent', (can_send('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c001','email','marketing','followup', (select id from channel_numbers where false limit 1),'x',null,'ai',false,false,null,'2026-03-10 15:00:00+00')).code, 'number_not_found');
  -- contact texts START -> clears DNC; but state must be re-granted explicitly
  insert into consent_events(dealer_id,contact_id,channel,purpose,action,source,disclosure_text_version,evidence)
   values ('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c001','sms','marketing','grant','sms_keyword','tcpa-v3','{"text":"START"}');
  perform t.eq('open DNC rows after START', (select count(*) from contact_dnc where contact_id='00000000-0000-0000-0000-00000000c001' and cleared_at is null)::int, 0);
  r := can_send('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c001','sms','marketing','followup','00000000-0000-0000-0000-0000000000b1','welcome back friend',null,'ai',false,false,null,'2026-03-10 15:00:00+00');
  perform t.eq('re-opt-in by the contact -> ok', r.code, 'ok');
  -- all-channel revoke
  insert into consent_events(dealer_id,contact_id,channel,purpose,action,source,note) values ('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c001',null,null,'revoke','staff_entry','do not contact (complaint)');
  r := can_send('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c001','sms','marketing','followup','00000000-0000-0000-0000-0000000000b1','welcome back friend',null,'ai',false,false,null,'2026-03-10 15:00:00+00');
  perform t.eq('all-channel DNC blocks sms', r.code, 'dnc_active');
  perform t.raises('even contact-initiated grant cannot clear all-channel DNC',
    $q$insert into consent_events(dealer_id,contact_id,channel,purpose,action,source,disclosure_text_version) values ('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c001','sms','marketing','grant','sms_keyword','v1')$q$, 'DNC_ACTIVE%');
  -- reply to a contact with DNC is also vetoed
  insert into messages(dealer_id,contact_id,number_id,channel,direction,body,created_at) values ('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c001','00000000-0000-0000-0000-0000000000b1','sms','inbound','hey','2026-03-10 14:55:00+00');
  r := can_send('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c001','sms','conversational','reply','00000000-0000-0000-0000-0000000000b1','replying anyway',null,'ai',false,false,null,'2026-03-10 15:00:00+00');
  perform t.eq('DNC beats reply window', r.code, 'dnc_active');
end $$;

-- 8. sanity vetoes
select t.eq('no address', (can_send(:d1,:nophone,'sms','marketing','followup',:n1,'x y z',null,'ai',false,false,null,:noon)).code, 'no_address');
select t.eq('cross-dealer contact', (can_send(:d2,:bob,'sms','marketing','followup',:n3,'x y z',null,'ai',false,false,null,:noon)).code, 'contact_not_found');
select t.eq('channel mismatch', (can_send(:d1,:bob,'sms','conversational','reply',:n2,'x y z',null,'ai',false,false,null,:noon)).code, 'number_channel_mismatch');
update leads set force_human = true where id = :lead1;
select t.eq('force_human silences AI', (can_send(:d1,:ann,'sms','marketing','followup',:n1,'x y z',:lead1,'ai',false,false,null,:noon)).code, 'human_owned') ;
update leads set force_human = false where id = :lead1;
update channel_numbers set status='paused' where id = :n3;
select t.eq('paused number', (can_send(:d2,:flo,'sms','marketing','followup',:n3,'x y z',null,'ai',false,false,null,:noon)).code, 'number_inactive');
update channel_numbers set status='active' where id = :n3;

-- 9. warm-up ladder
do $$ begin
  update channel_numbers set activated_at = '2026-03-10 00:00:00+00' where id = '00000000-0000-0000-0000-0000000000b3';
  perform t.eq('age 0d cap', number_daily_cap('00000000-0000-0000-0000-0000000000b3','2026-03-10 15:00+00'), 20);
  perform t.eq('age 3d cap', number_daily_cap('00000000-0000-0000-0000-0000000000b3','2026-03-13 15:00+00'), 20);
  perform t.eq('age 4d cap', number_daily_cap('00000000-0000-0000-0000-0000000000b3','2026-03-14 15:00+00'), 50);
  perform t.eq('age 8d cap', number_daily_cap('00000000-0000-0000-0000-0000000000b3','2026-03-18 15:00+00'), 100);
  perform t.eq('age 15d cap', number_daily_cap('00000000-0000-0000-0000-0000000000b3','2026-03-25 15:00+00'), 200);
  perform t.eq('age 31d unlimited', number_daily_cap('00000000-0000-0000-0000-0000000000b3','2026-04-10 15:00+00'), null::int);
  update channel_numbers set daily_cap_override = 30 where id = '00000000-0000-0000-0000-0000000000b3';
  perform t.eq('override lowers cap (age 15d)', number_daily_cap('00000000-0000-0000-0000-0000000000b3','2026-03-25 15:00+00'), 30);
  perform t.eq('override sets cap when formed', number_daily_cap('00000000-0000-0000-0000-0000000000b3','2026-04-10 15:00+00'), 30);
  update channel_numbers set daily_cap_override = null where id = '00000000-0000-0000-0000-0000000000b3';
end $$;

-- 10. cap + throttle + jitter + idempotency (commit mode). Contact Bob gets marketing consent.
insert into consent_events(dealer_id,contact_id,channel,purpose,action,source,disclosure_text_version)
 values (:d1,:bob,'sms','marketing','grant','web_form','tcpa-v3');
update channel_numbers set activated_at = '2026-03-10 00:00:00+00' where id = :n1;   -- age 0 => cap 20
do $$ declare r send_decision; i int; t0 timestamptz := '2026-03-10 15:00:00+00'; first_next timestamptz; nxt timestamptz; res uuid; begin
  r := can_send('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c002','sms','marketing','followup','00000000-0000-0000-0000-0000000000b1','Slot message number 0 about your visit',null,'ai',false,true,'idem-1',t0);
  perform t.eq('commit allow', r.code, 'reserved');
  res := r.reservation_id;
  select next_allowed_at into nxt from channel_numbers where id='00000000-0000-0000-0000-0000000000b1';
  perform t.ok('jitter within [throttle, throttle+jitter]', nxt >= t0 + interval '1200 ms' and nxt <= t0 + interval '2000 ms');
  r := can_send('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c002','sms','marketing','followup','00000000-0000-0000-0000-0000000000b1','Slot message number 0 about your visit',null,'ai',false,true,'idem-1',t0);
  perform t.eq('idempotent replay returns same reservation', r.reservation_id, res);
  r := can_send('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c002','sms','marketing','followup','00000000-0000-0000-0000-0000000000b1','Totally different words appear here now',null,'ai',false,false,null,t0 + interval '100 ms');
  perform t.eq('throttle delays the next send', r.code, 'throttle');
  perform t.eq('throttle not_before = next_allowed_at', r.not_before, nxt);
  -- fill the day to the cap using distinct copy so the anti-template gate stays out of the way
  for i in 1..19 loop
    t0 := t0 + interval '3 seconds';
    r := can_send('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c002','sms','marketing','followup','00000000-0000-0000-0000-0000000000b1',
                  'unique-' || i || ' ' || md5(i::text) || ' ' || md5((i*7)::text) || ' ' || md5((i*13)::text),null,'ai',false,true,null,t0);
    if r.verdict <> 'allow' then raise exception 'unexpected % % at i=%', r.code, r.reason, i; end if;
  end loop;
  t0 := t0 + interval '3 seconds';
  r := can_send('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c002','sms','marketing','followup','00000000-0000-0000-0000-0000000000b1','one more message past the cap',null,'ai',false,true,null,t0);
  perform t.eq('21st non-reply send -> daily_cap', r.code, 'daily_cap');
  perform t.eq('cap details', (r.details->>'cap')::int, 20);
  perform t.ok('daily_cap not_before is tomorrow morning local', r.not_before >= '2026-03-11 12:00:00+00'::timestamptz and r.not_before < '2026-03-11 13:00:00+00'::timestamptz);
  -- replies do not consume or hit the cap
  insert into messages(dealer_id,contact_id,number_id,channel,direction,body,created_at) values ('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c002','00000000-0000-0000-0000-0000000000b1','sms','inbound','ok thanks',t0);
  r := can_send('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c002','sms','conversational','reply','00000000-0000-0000-0000-0000000000b1','You are welcome, see you then!',null,'ai',false,true,null,t0 + interval '5 seconds');
  perform t.eq('reply passes while cap is exhausted', r.code, 'reserved');
  -- release gives the slot back
  perform release_send(res, 'provider error');
  t0 := t0 + interval '10 seconds';
  r := can_send('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c002','sms','marketing','followup','00000000-0000-0000-0000-0000000000b1','one more message past the cap now',null,'ai',false,true,null,t0);
  perform t.eq('release_send frees a cap slot', r.code, 'reserved');
  -- next day the counter resets
  r := can_send('00000000-0000-0000-0000-0000000000a1','00000000-0000-0000-0000-00000000c002','sms','marketing','followup','00000000-0000-0000-0000-0000000000b1','tomorrow is a fresh day to talk',null,'ai',false,false,null,'2026-03-11 13:00:00+00');
  perform t.eq('next local day resets the counter (age>=4d => cap 50)', r.code, 'ok');
end $$;

-- 11. anti-template (Deskcomm-style: 2 copies in window => 3rd vetoed; near-duplicates count; short/url/template exempt)
update channel_numbers set activated_at = '2025-01-01', warmup_enabled = false, throttle_ms = 0, jitter_max_ms = 0 where id = :n3;
insert into contacts(id,dealer_id,first_name,phone_e164) select gen_random_uuid(), :d2, 'C'||g, '+1555555'||(2000+g) from generate_series(1,6) g;
insert into consent_events(dealer_id,contact_id,channel,purpose,action,source,disclosure_text_version)
 select :d2, c.id, 'sms','marketing','grant','web_form','v3' from contacts c where c.dealer_id = :d2 and c.first_name like 'C%';
do $$ declare r send_decision; cs uuid[]; i int; t0 timestamptz := '2026-03-10 15:00:00+00'; begin
  select array_agg(id order by first_name) into cs from contacts where dealer_id='00000000-0000-0000-0000-0000000000a2' and first_name like 'C%';
  r := can_send('00000000-0000-0000-0000-0000000000a2', cs[1],'sms','marketing','followup','00000000-0000-0000-0000-0000000000b3','Hi Chris, the 2024 Civic you looked at is still here, come see it this weekend!',null,'ai',false,true,null,t0);
  perform t.eq('copy 1 ok', r.code, 'reserved');
  r := can_send('00000000-0000-0000-0000-0000000000a2', cs[2],'sms','marketing','followup','00000000-0000-0000-0000-0000000000b3','Hi Dana, the 2024 Civic you looked at is still here, come see it this weekend!',null,'ai',false,true,null,t0+interval '1 s');
  perform t.eq('copy 2 (name swapped) ok', r.code, 'reserved');
  r := can_send('00000000-0000-0000-0000-0000000000a2', cs[3],'sms','marketing','followup','00000000-0000-0000-0000-0000000000b3','Hi Erin, the 2024 Civic you looked at is still here, come see it this weekend!',null,'ai',false,true,null,t0+interval '2 s');
  perform t.eq('copy 3 (name swapped) -> template_repetition', r.code, 'template_repetition');
  r := can_send('00000000-0000-0000-0000-0000000000a2', cs[3],'sms','marketing','followup','00000000-0000-0000-0000-0000000000b3','Erin, we just got a 2022 Tacoma in trade with low miles. Want a quick video walkaround?',null,'ai',false,true,null,t0+interval '3 s');
  perform t.eq('genuinely different copy ok', r.code, 'reserved');
  r := can_send('00000000-0000-0000-0000-0000000000a2', cs[4],'sms','marketing','followup','00000000-0000-0000-0000-0000000000b3','Hi Dana, the 2024 Civic you looked at is still here, come see it this weekend!',null,'ai',true,true,null,t0+interval '4 s');
  perform t.eq('approved-template sends are exempt', r.code, 'reserved');
  for i in 1..3 loop
    r := can_send('00000000-0000-0000-0000-0000000000a2', cs[3+i],'sms','marketing','followup','00000000-0000-0000-0000-0000000000b3','ok sounds good',null,'ai',false,true,null,t0+interval '10 s'+i*interval '1 s');
    perform t.eq('short copy exempt #'||i, r.code, 'reserved');
  end loop;
  r := can_send('00000000-0000-0000-0000-0000000000a2', cs[5],'sms','marketing','followup','00000000-0000-0000-0000-0000000000b3','Book here https://x.test/book?id=1 ok',null,'ai',false,true,null,t0+interval '20 s');
  r := can_send('00000000-0000-0000-0000-0000000000a2', cs[6],'sms','marketing','followup','00000000-0000-0000-0000-0000000000b3','Book here https://x.test/book?id=1 ok',null,'ai',false,true,null,t0+interval '21 s');
  r := can_send('00000000-0000-0000-0000-0000000000a2', cs[1],'sms','marketing','followup','00000000-0000-0000-0000-0000000000b3','Book here https://x.test/book?id=1 ok',null,'ai',false,true,null,t0+interval '22 s');
  perform t.eq('scheduling-link copy exempt even when repeated', r.code, 'reserved');
  perform t.eq('jaccard sanity', jaccard(copy_tokens('a b c'), copy_tokens('a b d')), 0.5::numeric);
end $$;
\echo CAN_SEND TESTS PASSED
