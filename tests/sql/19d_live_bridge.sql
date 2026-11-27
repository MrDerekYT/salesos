-- Live bridge: salesos.* and AgentPhone public.* -> salesos_ai, and Derek's provided-number consent policy.
\set ON_ERROR_STOP 1
begin;
insert into salesos.accounts (id, name, industry, feed_token, created_at) values ('acct-bridge-1', 'Bridge Motors', 'auto', 'tok-bridge', now()::text);
insert into salesos.users (id, account_id, email, password_hash, name, role, languages, timezone, created_at)
values ('00000000-0000-0000-0000-00000000b001', 'acct-bridge-1', 'rep@bridge.test', 'x', 'Rep', 'owner', 'en', 'America/New_York', now()::text);
select t.ok('account -> dealer', exists (select 1 from salesos_ai.dealers where salesos_account_id = 'acct-bridge-1'));
select t.ok('user -> dealer member', exists (select 1 from salesos_ai.dealer_members where salesos_user_id = '00000000-0000-0000-0000-00000000b001' and role = 'owner'));

insert into salesos.customers (id, account_id, full_name, first_name, phone, source, stage, tags, consent_sms, consent_email, consent_call, do_not_contact, created_at, updated_at)
values ('cust-b1', 'acct-bridge-1', 'Pat Buyer', 'Pat', '(954) 555-0101', 'facebook', 'NEW', '[]', 0, 0, 0, 0, now()::text, now()::text),
       ('cust-b2', 'acct-bridge-1', 'No Contact', 'No', '954-555-0102', 'prospect', 'CONTACTED', '[]', 0, 0, 0, 1, now()::text, now()::text);
select t.eq('customer phone normalized', (select phone_e164 from salesos_ai.contacts where salesos_customer_id = 'cust-b1'), '+19545550101');
select t.eq('provided number => inquiry_followup grant',
  (select source::text || '/' || purpose::text from salesos_ai.consent_events ce join salesos_ai.contacts c on c.id = ce.contact_id where c.salesos_customer_id = 'cust-b1' and ce.action = 'grant'),
  'provided_number_inquiry/inquiry_followup');
select t.ok('grant counts as evidence', (select s.evidence_ok from salesos_ai.contact_consent_state s join salesos_ai.contacts c on c.id = s.contact_id where c.salesos_customer_id = 'cust-b1' and s.purpose = 'inquiry_followup'));
select t.ok('do_not_contact => all-channel DNC', exists (select 1 from salesos_ai.contact_dnc d join salesos_ai.contacts c on c.id = d.contact_id where c.salesos_customer_id = 'cust-b2' and d.channel is null and d.cleared_at is null));
select t.ok('do_not_contact => no grant', not exists (select 1 from salesos_ai.consent_events ce join salesos_ai.contacts c on c.id = ce.contact_id where c.salesos_customer_id = 'cust-b2' and ce.action = 'grant'));
select t.eq('stage mapped', (select stage from salesos_ai.leads where salesos_customer_id = 'cust-b2'), 'contacted');

-- the gate: inquiry follow-up allowed, marketing still needs express consent, quiet hours always apply
insert into salesos_ai.channel_numbers (dealer_id, channel, provider, address, activated_at)
select id, 'sms', 'mock', '+15555550900', now() from salesos_ai.dealers where salesos_account_id = 'acct-bridge-1';
create temp table g as
select c.dealer_id, c.id as contact_id, n.id as number_id from salesos_ai.contacts c join salesos_ai.channel_numbers n on n.dealer_id = c.dealer_id
 where c.salesos_customer_id = 'cust-b1';
select t.eq('inquiry follow-up allowed',
  (select (salesos_ai.can_send(dealer_id, contact_id, 'sms', 'inquiry_followup', 'followup', number_id, 'Hi Pat, the Tahoe you asked about is still here - want to see it Saturday?', null, 'ai', false, false, null, '2026-11-27 15:00:00+00')).verdict::text from g), 'allow');
select t.eq('conversational follow-up allowed by the same grant',
  (select (salesos_ai.can_send(dealer_id, contact_id, 'sms', 'conversational', 'followup', number_id, 'Pat, still want to set up that test drive this week?', null, 'ai', false, false, null, '2026-11-27 15:05:00+00')).verdict::text from g), 'allow');
select t.eq('marketing blast vetoed (no express consent)',
  (select (salesos_ai.can_send(dealer_id, contact_id, 'sms', 'marketing', 'cold', number_id, 'Weekend blowout sale on every SUV!', null, 'ai', false, false, null, '2026-11-27 15:10:00+00')).code from g), 'no_consent');
select t.eq('quiet hours still apply',
  (select (salesos_ai.can_send(dealer_id, contact_id, 'sms', 'inquiry_followup', 'followup', number_id, 'Late check-in on the Tahoe', null, 'ai', false, false, null, '2026-11-27 03:00:00+00')).code from g), 'quiet_hours');

-- AgentPhone: lead with ok_to_text=false => sms opt-out; inbound text => queued for agentphone-bridge; never breaks the insert
insert into public.leads (phone, source, first_name, ok_to_text) values ('+19545550103', 'sms', 'Optout', false);
select t.ok('ok_to_text=false => sms DNC', exists (select 1 from salesos_ai.contact_dnc d join salesos_ai.contacts c on c.id = d.contact_id where c.phone_e164 = '+19545550103' and d.channel = 'sms'));
insert into public.leads (phone, source, first_name) values ('+19545550104', 'phone_call', 'Caller');
select t.ok('AgentPhone lead => SoldByDerek grant', exists (select 1 from salesos_ai.consent_events ce join salesos_ai.contacts c on c.id = ce.contact_id join salesos_ai.dealers d on d.id = c.dealer_id
  where c.phone_e164 = '+19545550104' and d.bridge_key = 'soldbyderek' and ce.source = 'provided_number_inquiry'));
insert into public.messages (agentphone_message_id, direction, channel, from_number, to_number, body) values ('ap-1', 'inbound', 'sms', '+19545550104', '+17542291849', 'is the tahoe still there?');
select t.eq('inbound AgentPhone text queued', (select status from salesos_ai.agentphone_inbox i join public.messages m on m.id = i.source_id where m.agentphone_message_id = 'ap-1'), 'pending');
insert into public.messages (agentphone_message_id, direction, channel, from_number, body) values ('ap-voice', 'inbound', 'voice', '+19545550104', null);
select t.ok('voice turns are not queued', not exists (select 1 from salesos_ai.agentphone_inbox i join public.messages m on m.id = i.source_id where m.agentphone_message_id = 'ap-voice'));
insert into public.calls (agentphone_call_id, direction, from_number, to_number, summary) values ('call-1', 'inbound', '+19545550104', '+17542291849', 'Asked about the Tahoe, wants Saturday.');
select t.eq('call recorded as lead activity', (salesos_ai.bridge_record_agentphone_call((select id from salesos_ai.agentphone_inbox where kind = 'call' limit 1)))->>'status', 'done');

-- vehicles: salesos price cut -> vehicle_events price_drop; the lead that asked about THAT car gets an inquiry follow-up
insert into salesos.vehicles (id, account_id, vin, stock_number, year, make, model, price, photo_urls, status, source, marketing_status, date_added, updated_at)
values ('veh-b1', 'acct-bridge-1', '1GNSKCKD5PR000001', 'T1234', '2024', 'Chevrolet', 'Tahoe', 61000, '[]', 'available', 'feed', 'none', now()::text, now()::text);
update salesos.customers set vehicle_interest = 'Tahoe stock T1234' where id = 'cust-b1';
select t.ok('lead linked to the car it asked about', (select vehicle_id is not null from salesos_ai.leads where salesos_customer_id = 'cust-b1'));
update salesos.vehicles set price = 58500 where id = 'veh-b1';
select t.ok('price cut => price_drop event', exists (select 1 from salesos_ai.vehicle_events e join salesos_ai.vehicles v on v.id = e.vehicle_id where v.salesos_vehicle_id = 'veh-b1' and e.kind = 'price_drop'));
rollback;
select 'PASSED 19d_live_bridge';
