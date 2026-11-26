\set ON_ERROR_STOP 1
-- Feature 7: MCP keys (hashed, role-capped), staff allow-list, scoped tools, drafts-only customer messaging, audit log
\set d '\'00000000-0000-0000-0018-0000000000a1\'::uuid'
\set own '\'00000000-0000-0000-0018-0000000000b1\'::uuid'
\set rep '\'00000000-0000-0000-0018-0000000000b2\'::uuid'
\set rep2 '\'00000000-0000-0000-0018-0000000000b3\'::uuid'
\set mgr '\'00000000-0000-0000-0018-0000000000b4\'::uuid'
insert into dealers(id,name,timezone) values (:d,'MCP Motors','America/New_York'), ('00000000-0000-0000-0018-0000000000a2','Other Motors','America/New_York');
insert into dealer_members(user_id,dealer_id,role) values (:own,:d,'owner'),(:rep,:d,'sales'),(:rep2,:d,'sales'),(:mgr,:d,'manager');
insert into channel_numbers(id,dealer_id,channel,address,activated_at) values ('00000000-0000-0000-0018-0000000000a8', :d, 'sms', '+15555518999', '2026-01-01');
insert into contacts(id,dealer_id,first_name,last_name,phone_e164) values
 ('00000000-0000-0000-0018-0000000000c1', :d, 'Sarah', 'Lopez', '+15555518001'),
 ('00000000-0000-0000-0018-0000000000c2', :d, 'Sarah', 'Kim',   '+15555518002'),
 ('00000000-0000-0000-0018-0000000000c3', :d, 'Tom',   'Reyes', '+15555518003'),
 ('00000000-0000-0000-0018-0000000000c4', :d, 'Uma',   'Noor',  null);
insert into consent_events(dealer_id,contact_id,channel,purpose,action,source,disclosure_text_version) values
 (:d,'00000000-0000-0000-0018-0000000000c1','sms','conversational','grant','web_form',null),
 (:d,'00000000-0000-0000-0018-0000000000c3','sms','conversational','grant','web_form',null);
select record_opt_out(:d,'00000000-0000-0000-0018-0000000000c3',null,'sms_keyword','{}','STOP');
insert into leads(id,dealer_id,contact_id,stage,assigned_to) values
 ('00000000-0000-0000-0018-0000000000e1', :d,'00000000-0000-0000-0018-0000000000c1','qualifying', :rep),
 ('00000000-0000-0000-0018-0000000000e2', :d,'00000000-0000-0000-0018-0000000000c2','contacted',  :rep2),
 ('00000000-0000-0000-0018-0000000000e3', :d,'00000000-0000-0000-0018-0000000000c3','contacted',  null),
 ('00000000-0000-0000-0018-0000000000e4', :d,'00000000-0000-0000-0018-0000000000c4','new',        :rep);
insert into messages(dealer_id,lead_id,contact_id,channel,direction,body,created_at) values
 (:d,'00000000-0000-0000-0018-0000000000e1','00000000-0000-0000-0018-0000000000c1','sms','inbound','is the Tacoma still there?', now() - interval '3 hours');
insert into vehicles(dealer_id,vin,year,make,model,price_cents,status,condition) values
 (:d,'3TMCZ5AN0NM000001',2022,'Toyota','Tacoma',3390000,'available','used'),
 (:d,'3TMCZ5AN0NM000002',2022,'Toyota','Tacoma',3150000,'sold','used'),
 (:d,'3TMCZ5AN0NM000003',2023,'Toyota','Tacoma',3890000,'available','used');

-- ---------- keys ----------
create temp table k (label text primary key, id uuid, key text);
grant all on k to authenticated;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0018-0000000000b1"}', false);
set role authenticated;
insert into k select 'owner_admin', key_id, api_key from create_mcp_api_key('00000000-0000-0000-0018-0000000000a1', 'Claude desktop', 'admin');
insert into k select 'rep_sales', key_id, api_key from create_mcp_api_key('00000000-0000-0000-0018-0000000000a1', 'Rep laptop', 'sales', '00000000-0000-0000-0018-0000000000b2');
insert into k select 'rep_viewer', key_id, api_key from create_mcp_api_key('00000000-0000-0000-0018-0000000000a1', 'Rep read-only', 'viewer', '00000000-0000-0000-0018-0000000000b2');
insert into k select 'mgr_mgr', key_id, api_key from create_mcp_api_key('00000000-0000-0000-0018-0000000000a1', 'Mgr', 'manager', '00000000-0000-0000-0018-0000000000b4');
insert into k select 'expired', key_id, api_key from create_mcp_api_key('00000000-0000-0000-0018-0000000000a1', 'Old', 'sales', '00000000-0000-0000-0018-0000000000b2', now() - interval '1 minute');
select t.raises('key role cannot exceed the acting user', $q$select * from create_mcp_api_key('00000000-0000-0000-0018-0000000000a1','x','manager','00000000-0000-0000-0018-0000000000b2')$q$, '%exceeds%');
select t.raises('non-member acting user refused', $q$select * from create_mcp_api_key('00000000-0000-0000-0018-0000000000a1','x','viewer','00000000-0000-0000-0018-0000000000ff')$q$, '%not a member%');
select t.raises('owner cannot read key hashes', $q$select key_hash from mcp_api_keys$q$, '%permission denied%');
select t.eq('owner sees key metadata (prefix only)', (select count(*) from mcp_api_keys where key_prefix like 'sos_%')::int, 5);
reset role;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0018-0000000000b2"}', false);
set role authenticated;
select t.raises('sales rep cannot mint keys', $q$select * from create_mcp_api_key('00000000-0000-0000-0018-0000000000a1','x','viewer')$q$, '%forbidden%');
select t.eq('sales rep cannot list keys', (select count(*) from mcp_api_keys)::int, 0);
select t.raises('authenticated cannot verify keys', $q$select * from verify_mcp_api_key('sos_x')$q$, '%permission denied%');
select t.raises('authenticated cannot call MCP tools directly', $q$select mcp_get_lead('00000000-0000-0000-0018-0000000000a1','00000000-0000-0000-0018-0000000000b2','admin','00000000-0000-0000-0018-0000000000e1')$q$, '%permission denied%');
reset role;
set role anon;
select t.raises('anon cannot verify keys', $q$select * from verify_mcp_api_key('sos_x')$q$, '%permission denied%');
reset role;
select set_config('request.jwt.claims', '', false);

select t.ok('key format sos_ + 64 hex, plaintext not stored', (select bool_and(key ~ '^sos_[0-9a-f]{64}$') from k) and not exists (select 1 from mcp_api_keys a join k on k.key = a.key_hash));
select t.eq('verify: good key => role + scopes', (select role || ':' || array_length(scopes,1) from verify_mcp_api_key((select key from k where label = 'rep_sales'))), 'sales:5');
select t.ok('verify stamps last_used_at', (select last_used_at is not null from mcp_api_keys where id = (select id from k where label = 'rep_sales')));
select t.eq('verify: wrong key => nothing', (select count(*) from verify_mcp_api_key('sos_' || repeat('0', 64)))::int, 0);
select t.eq('verify: expired => nothing', (select count(*) from verify_mcp_api_key((select key from k where label = 'expired')))::int, 0);
select revoke_mcp_api_key((select id from k where label = 'rep_viewer'), :own);
select t.eq('verify: revoked => nothing', (select count(*) from verify_mcp_api_key((select key from k where label = 'rep_viewer')))::int, 0);
update dealer_members set role = 'viewer' where user_id = :mgr and dealer_id = :d;
select t.eq('demotion caps the key at once', (select role from verify_mcp_api_key((select key from k where label = 'mgr_mgr'))), 'viewer');
delete from dealer_members where user_id = :mgr and dealer_id = :d;
select t.eq('removed member => key dead', (select count(*) from verify_mcp_api_key((select key from k where label = 'mgr_mgr')))::int, 0);
insert into dealer_members(user_id,dealer_id,role) values (:mgr,:d,'manager');

-- ---------- staff texting allow-list ----------
insert into staff_identities(dealer_id,user_id,channel,address,status,verified_at) values
 (:d, :rep, 'sms', '+15555518101', 'active', now()),
 (:d, :rep2,'sms', '+15555518102', 'pending', null),
 (:d, :own, 'sms', '+15555518103', 'active', now()),
 (:d, :mgr, 'email', 'mgr@mcp.test', 'active', now());
select t.eq('active identity resolves to the member role', (select role from resolve_staff_sender(:d, 'sms', '+15555518101')), 'sales');
select t.eq('pending identity does not resolve', (select count(*) from resolve_staff_sender(:d, 'sms', '+15555518102'))::int, 0);
select t.eq('unknown number does not resolve', (select count(*) from resolve_staff_sender(:d, 'sms', '+15555518001'))::int, 0);
select t.eq('owner by text is capped to manager', (select role from resolve_staff_sender(:d, 'sms', '+15555518103')), 'manager');
select t.eq('email match is case-insensitive', (select role from resolve_staff_sender(:d, 'email', ' MGR@mcp.test ')), 'manager');
select t.eq('same number at another dealer does not resolve', (select count(*) from resolve_staff_sender('00000000-0000-0000-0018-0000000000a2', 'sms', '+15555518101'))::int, 0);
update staff_identities set status = 'revoked', revoked_at = now() where address = '+15555518101';
select t.eq('revoked identity stops resolving', (select count(*) from resolve_staff_sender(:d, 'sms', '+15555518101'))::int, 0);
select t.raises('active requires verification', $q$insert into staff_identities(dealer_id,user_id,channel,address,status) values ('00000000-0000-0000-0018-0000000000a1','00000000-0000-0000-0018-0000000000b3','sms','+15555518104','active')$q$, '%check%');

-- ---------- tools ----------
select t.raises('viewer cannot move stages', $q$select mcp_move_stage('00000000-0000-0000-0018-0000000000a1','00000000-0000-0000-0018-0000000000b2','viewer','00000000-0000-0000-0018-0000000000e1','negotiating')$q$, '%forbidden%');
select t.raises('rep cannot see another rep''s lead (not_found, no oracle)', $q$select mcp_get_lead('00000000-0000-0000-0018-0000000000a1','00000000-0000-0000-0018-0000000000b2','sales','00000000-0000-0000-0018-0000000000e2')$q$, 'not_found%');
select t.raises('missing lead looks identical', $q$select mcp_get_lead('00000000-0000-0000-0018-0000000000a1','00000000-0000-0000-0018-0000000000b2','sales','00000000-0000-0000-0018-0000000000ee')$q$, 'not_found%');
select t.raises('lead from another dealer is not found', $q$select mcp_get_lead('00000000-0000-0000-0018-0000000000a2','00000000-0000-0000-0018-0000000000b4','manager','00000000-0000-0000-0018-0000000000e1')$q$, 'not_found%');
select t.ok('manager sees every lead', mcp_get_lead(:d, :mgr, 'manager', '00000000-0000-0000-0018-0000000000e2') is not null);
select t.ok('get_lead: masked phone, recent message, reachability', (select (j->'contact'->>'phone_last4') = '8001' and jsonb_array_length(j->'recent_messages') = 1 and (j->'reachable'->>'conversational_channel') = 'sms' and not (j->'contact' ? 'phone_e164')
   from (select mcp_get_lead(:d, :rep, 'sales', '00000000-0000-0000-0018-0000000000e1') j) x));
select t.eq('find_leads: rep sees own + unassigned Sarahs only', (select string_agg(name, ',' order by name) from mcp_find_leads(:d, :rep, 'sales', 'sarah')), 'Sarah Lopez');
select t.eq('find_leads: manager sees both Sarahs (ambiguity is the caller''s job)', (select count(*) from mcp_find_leads(:d, :mgr, 'manager', 'sarah'))::int, 2);
select t.eq('find_leads: 1-char queries return nothing', (select count(*) from mcp_find_leads(:d, :mgr, 'manager', 's'))::int, 0);
select t.ok('list_attention returns the unanswered inbound for the rep', exists (select 1 from mcp_list_attention(:d, :rep, 'sales') where lead_id = '00000000-0000-0000-0018-0000000000e1'));
select t.ok('list_attention hides another rep''s leads', not exists (select 1 from mcp_list_attention(:d, :rep, 'sales') where lead_id = '00000000-0000-0000-0018-0000000000e2'));

create temp table mv as select mcp_move_stage(:d, :rep, 'sales', '00000000-0000-0000-0018-0000000000e1', 'negotiating', 'texted: move Sarah to negotiating') j;
select t.eq('move_stage applied', (select j->>'decision' from mv), 'applied');
select t.eq('lead now negotiating', (select stage from leads where id = '00000000-0000-0000-0018-0000000000e1'), 'negotiating');
select t.ok('move recorded as a human change by the rep', exists (select 1 from lead_activities where id = (select (j->>'undo_activity_id')::uuid from mv) and actor_kind = 'human' and actor_id = :rep));
select t.ok('undo via returned activity id', undo_stage_change((select (j->>'undo_activity_id')::uuid from mv), :rep) is not null);
select t.eq('stage back to qualifying', (select stage from leads where id = '00000000-0000-0000-0018-0000000000e1'), 'qualifying');
select t.raises('unknown stage refused', $q$select mcp_move_stage('00000000-0000-0000-0018-0000000000a1','00000000-0000-0000-0018-0000000000b2','sales','00000000-0000-0000-0018-0000000000e1','teleported')$q$, '%');

select t.ok('create_task for self', mcp_create_task(:d, :rep, 'sales', '00000000-0000-0000-0018-0000000000e1', 'Call Sarah about trade', now() + interval '1 day') is not null);
select t.eq('task is a scheduled rep callback', (select kind || '/' || status from followups where lead_id = '00000000-0000-0000-0018-0000000000e1' and reason = 'Call Sarah about trade'), 'rep_callback/scheduled');
select t.raises('title too short', $q$select mcp_create_task('00000000-0000-0000-0018-0000000000a1','00000000-0000-0000-0018-0000000000b2','sales','00000000-0000-0000-0018-0000000000e1','x', now() + interval '1 hour')$q$, 'invalid%');
select t.raises('due date too far', $q$select mcp_create_task('00000000-0000-0000-0018-0000000000a1','00000000-0000-0000-0018-0000000000b2','sales','00000000-0000-0000-0018-0000000000e1','Call back', now() + interval '200 days')$q$, 'invalid%');
select t.raises('sales cannot assign to others', $q$select mcp_create_task('00000000-0000-0000-0018-0000000000a1','00000000-0000-0000-0018-0000000000b2','sales','00000000-0000-0000-0018-0000000000e1','Call back', now() + interval '1 hour', '00000000-0000-0000-0018-0000000000b3')$q$, 'forbidden%');
select t.ok('manager can assign to a rep', mcp_create_task(:d, :mgr, 'manager', '00000000-0000-0000-0018-0000000000e2', 'Call Sarah K', now() + interval '1 hour', :rep2) is not null);

select t.eq('search_inventory: tacoma under 35k excludes sold', (select string_agg(vin, ',') from mcp_search_inventory(:d, 'viewer', null, 'tacoma', null, null, 3500000)), '3TMCZ5AN0NM000001');
select t.eq('search_inventory: sorted by price', (select string_agg(vin, ',') from mcp_search_inventory(:d, 'viewer', 'toyota', 'tacoma')), '3TMCZ5AN0NM000001,3TMCZ5AN0NM000003');

create temp table dr as select mcp_draft_message(:d, :rep, 'sales', '00000000-0000-0000-0018-0000000000e1', 'Hi Sarah, yes, the 2022 Tacoma is here. Want to see it Saturday?') j;
select t.eq('draft_message => awaiting_review, never sent', (select j->>'status' from dr), 'awaiting_review');
select t.ok('draft row is human-actor, awaiting review, no message row', (select status = 'awaiting_review' and actor = 'human' and evidence->>'source' = 'mcp' from outbound_drafts where id = (select (j->>'draft_id')::uuid from dr))
   and not exists (select 1 from messages where lead_id = '00000000-0000-0000-0018-0000000000e1' and direction = 'outbound'));
select t.eq('reply window detected (inbound 3h ago)', (select kind::text from outbound_drafts where id = (select (j->>'draft_id')::uuid from dr)), 'reply');
select t.eq('opted-out contact => refused (no draft)', (select j->>'code' from (select mcp_draft_message(:d, :rep, 'sales', '00000000-0000-0000-0018-0000000000e3', 'Hello Tom') j) x), 'unreachable');
select t.eq('no phone/email => unreachable', (select j->>'code' from (select mcp_draft_message(:d, :rep, 'sales', '00000000-0000-0000-0018-0000000000e4', 'Hello Uma') j) x), 'unreachable');
select t.raises('empty body refused', $q$select mcp_draft_message('00000000-0000-0000-0018-0000000000a1','00000000-0000-0000-0018-0000000000b2','sales','00000000-0000-0000-0018-0000000000e1','  ')$q$, 'invalid%');
select t.eq('no extra drafts for refused requests', (select count(*) from outbound_drafts where dealer_id = :d)::int, 1);

-- ---------- audit ----------
select t.ok('audit insert', mcp_audit(:d, 'api_key', (select id from k where label = 'rep_sales'), null, :rep, 'move_stage', '{"stage":"negotiating"}', 'ok', '00000000-0000-0000-0018-0000000000e1') > 0);
select t.raises('audit rows cannot be edited', $q$update mcp_audit_log set result_code = 'x'$q$, '%append-only%');
select t.raises('audit rows cannot be deleted', $q$delete from mcp_audit_log$q$, '%append-only%');
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0018-0000000000b1"}', false);
set role authenticated;
select t.eq('owner reads the audit log', (select count(*) from mcp_audit_log)::int, 1);
select t.raises('authenticated cannot write audit rows', $q$select mcp_audit('00000000-0000-0000-0018-0000000000a1','api_key',null,null,null,'x','{}','ok')$q$, '%permission denied%');
reset role;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0018-0000000000b2"}', false);
set role authenticated;
select t.eq('sales rep cannot read the audit log', (select count(*) from mcp_audit_log)::int, 0);
select t.eq('rep sees only own staff identity', (select count(*) from staff_identities)::int, 1);
reset role;
select set_config('request.jwt.claims', '', false);
select 'MCP STAFF TESTS PASSED';
