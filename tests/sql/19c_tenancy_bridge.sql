\set ON_ERROR_STOP 1
-- Tenancy bridge: original single-user model (profiles/leads.user_id) on top of dealers.
insert into auth.users(id,email) values
 ('00000000-0000-0000-0000-0000000009a1','alice@example.com'),
 ('00000000-0000-0000-0000-0000000009a2','bob@example.com'),
 ('00000000-0000-0000-0000-0000000009a3','rep@example.com') on conflict do nothing;
insert into profiles(id,email,full_name) values
 ('00000000-0000-0000-0000-0000000009a1','alice@example.com','Alice Motors'),
 ('00000000-0000-0000-0000-0000000009a2','bob@example.com',null),
 ('00000000-0000-0000-0000-0000000009a3','rep@example.com','Rep') on conflict do nothing;

select t.eq('signup creates a personal dealer', (select count(*) from dealers where owner_user_id='00000000-0000-0000-0000-0000000009a1' and is_personal)::int, 1);
select t.eq('personal dealer named from profile', (select name from dealers where owner_user_id='00000000-0000-0000-0000-0000000009a1' and is_personal), 'Alice Motors');
select t.eq('owner membership created', (select role from dealer_members m join dealers d on d.id=m.dealer_id where d.owner_user_id='00000000-0000-0000-0000-0000000009a1' and m.user_id='00000000-0000-0000-0000-0000000009a1'), 'owner');
select t.eq('ensure_personal_dealer is idempotent', public.ensure_personal_dealer('00000000-0000-0000-0000-0000000009a1'), (select id from dealers where owner_user_id='00000000-0000-0000-0000-0000000009a1' and is_personal));

-- the Next.js app inserts leads exactly like the original schema (user_id implied by auth.uid())
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000009a1"}', false);
set role authenticated;
insert into leads(name,email,phone,stage,value) values ('Sarah Lee Jones','Sarah@Example.com','(555) 201-7788','Lead In',32500.50);
reset role;
select t.eq('lead user_id defaults to auth.uid()', (select user_id from leads where name='Sarah Lee Jones'), '00000000-0000-0000-0000-0000000009a1'::uuid);
select t.eq('lead dealer_id filled', (select dealer_id from leads where name='Sarah Lee Jones'), public.ensure_personal_dealer('00000000-0000-0000-0000-0000000009a1'));
select t.eq('assigned_to defaults to owner', (select assigned_to from leads where name='Sarah Lee Jones'), '00000000-0000-0000-0000-0000000009a1'::uuid);
select t.eq('display stage normalised', (select stage from leads where name='Sarah Lee Jones'), 'new');
select t.eq('value_cents synced on insert', (select value_cents from leads where name='Sarah Lee Jones'), 3250050::bigint);
select t.eq('contact phone E.164', (select c.phone_e164 from leads l join contacts c on c.id=l.contact_id where l.name='Sarah Lee Jones'), '+15552017788');
select t.eq('contact email lowercased', (select c.email from leads l join contacts c on c.id=l.contact_id where l.name='Sarah Lee Jones'), 'sarah@example.com');
select t.eq('contact name split', (select c.first_name || '|' || c.last_name from leads l join contacts c on c.id=l.contact_id where l.name='Sarah Lee Jones'), 'Sarah|Lee Jones');
update leads set value = 40000 where name='Sarah Lee Jones';
select t.eq('value -> value_cents on update', (select value_cents from leads where name='Sarah Lee Jones'), 4000000::bigint);
update leads set value_cents = 1234500 where name='Sarah Lee Jones';
select t.eq('value_cents -> value on update', (select value from leads where name='Sarah Lee Jones'), 12345::numeric);
update leads set stage = 'Closed Won' where name='Sarah Lee Jones';
select t.eq('display stage normalised on update', (select stage from leads where name='Sarah Lee Jones'), 'won');
select t.eq('phone normaliser: 11 digits', public.normalize_phone_e164('1-555-201-7788'), '+15552017788');
select t.eq('phone normaliser: garbage -> null', public.normalize_phone_e164('call me'), null::text);
select t.eq('phone normaliser: intl', public.normalize_phone_e164('+44 20 7946 0958'), '+442079460958');

-- Bob's lead
select public.ensure_personal_dealer('00000000-0000-0000-0000-0000000009a1') as alice_dealer \gset
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000009a2"}', false);
set role authenticated;
insert into leads(name,phone) values ('Bob Customer','5552019999');
select t.eq('bob sees only his lead', (select count(*) from leads)::int, 1);
select t.eq('bob sees only his contact', (select count(*) from contacts)::int, 1);
select t.eq('bob sees only his dealer', (select count(*) from dealers)::int, 1);
select t.raises('bob cannot insert a lead into alice''s dealer',
  format($q$insert into leads(dealer_id,name) values (%L,'x')$q$, :'alice_dealer'), '%row-level security%');
reset role;
select set_config('request.jwt.claims', '', false);

-- a rep joins Alice's dealer: sees only leads assigned to them
insert into dealer_members(user_id,dealer_id,role) values ('00000000-0000-0000-0000-0000000009a3', public.ensure_personal_dealer('00000000-0000-0000-0000-0000000009a1'), 'sales');
insert into leads(dealer_id,user_id,name,phone) values (public.ensure_personal_dealer('00000000-0000-0000-0000-0000000009a1'),'00000000-0000-0000-0000-0000000009a1','Unassigned Uma','5552010000');
update leads set assigned_to='00000000-0000-0000-0000-0000000009a3' where name='Unassigned Uma';
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000009a3"}', false);
set role authenticated;
select t.eq('rep sees only the lead assigned to them', (select string_agg(name, ',') from leads), 'Unassigned Uma');
select t.eq('rep sees only that lead''s contact', (select count(*) from contacts)::int, 1);
select t.eq('rep sees only their own memberships', (select count(*) from dealer_members where user_id <> '00000000-0000-0000-0000-0000000009a3')::int, 0);
select t.raises('rep cannot add members', format($q$insert into dealer_members(user_id,dealer_id,role) values (gen_random_uuid(), %L, 'owner')$q$, :'alice_dealer'), '%row-level security%');
reset role;
select set_config('request.jwt.claims', '{"sub":"00000000-0000-0000-0000-0000000009a1"}', false);
set role authenticated;
select t.eq('owner sees every lead in the dealer', (select count(*) from leads)::int, 2);
select t.eq('owner sees team', (select count(*) from dealer_members)::int, 2);
reset role;
select set_config('request.jwt.claims', '', false);
set role anon;
select t.eq('anon reads no leads', (select count(*) from leads)::int, 0);
select t.raises('anon has no access to contacts', $q$select count(*) from contacts$q$, '%permission denied%');
reset role;
\echo TENANCY BRIDGE TESTS PASSED
