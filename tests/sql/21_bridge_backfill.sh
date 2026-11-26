#!/usr/bin/env bash
# Upgrade path: a project that already ran the original schema.sql and has data, then gets the new migrations.
set -euo pipefail
cd "$(dirname "$0")/../.."
DB=salesos_backfill
P="bash scripts/pg-local.sh psql -v ON_ERROR_STOP=1"
$P -d postgres -qc "drop database if exists $DB with (force)" -c "create database $DB"
$P -d $DB -q -f tests/sql/00_supabase_shim.sql
$P -d $DB -q -f supabase/schema.sql           # the legacy script exactly as Derek may have run it
$P -d $DB -q <<'SQL'
insert into auth.users(id,email) values ('00000000-0000-0000-0000-00000000aa01','legacy@example.com');
insert into profiles(id,email,full_name) values ('00000000-0000-0000-0000-00000000aa01','legacy@example.com','Legacy Lot');
insert into leads(user_id,name,email,phone,stage,value) values
 ('00000000-0000-0000-0000-00000000aa01','Ann Old','ann@example.com','555.111.2222','Negotiation',18000),
 ('00000000-0000-0000-0000-00000000aa01','Ned NoPhone',null,null,null,null),
 (null,'Orphan Ollie',null,'+1 555 333 4444','qualified',5);
SQL
for m in supabase/migrations/*.sql; do $P -d $DB -q -f "$m" >/dev/null 2>&1 || { echo "FAIL applying $m"; $P -d $DB -q -f "$m" 2>&1 | grep ERROR; exit 1; }; done
$P -d $DB -q -f tests/sql/01_helpers.sql >/dev/null
$P -d $DB -q <<'SQL' 2>&1 | grep -E "ok |FAIL|ERROR|PASSED"
select t.eq('legacy user got a personal dealer', (select count(*) from dealers where owner_user_id='00000000-0000-0000-0000-00000000aa01')::int, 1);
select t.eq('all leads have a dealer', (select count(*) from leads where dealer_id is null)::int, 0);
select t.eq('all leads have a contact', (select count(*) from leads where contact_id is null)::int, 0);
select t.eq('orphan lead went to Unassigned', (select d.name from leads l join dealers d on d.id=l.dealer_id where l.name='Orphan Ollie'), 'Unassigned (migrated)');
select t.eq('legacy stage mapped', (select stage from leads where name='Ann Old'), 'negotiating');
select t.eq('null stage -> new', (select stage from leads where name='Ned NoPhone'), 'new');
select t.eq('value_cents backfilled', (select value_cents from leads where name='Ann Old'), 1800000::bigint);
select t.eq('assigned_to backfilled', (select assigned_to from leads where name='Ann Old'), '00000000-0000-0000-0000-00000000aa01'::uuid);
select t.eq('legacy phone normalised', (select c.phone_e164 from leads l join contacts c on c.id=l.contact_id where l.name='Ann Old'), '+15551112222');
select t.eq('dealer settings seeded for backfilled dealers', (select count(*) from dealers d where not exists (select 1 from dealer_settings s where s.dealer_id=d.id))::int, 0);
\echo BACKFILL TESTS PASSED
SQL
# re-apply everything: still idempotent with data present
for m in supabase/migrations/*.sql; do $P -d $DB -q -f "$m" >/dev/null 2>&1 || { echo "FAIL re-applying $m"; exit 1; }; done
echo "re-apply OK"
