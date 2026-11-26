#!/usr/bin/env bash
# Proves the per-number advisory lock: two concurrent can_send(commit=true) calls on one number must serialize,
# and with cap-1 slots left exactly ONE may be reserved (no read-then-act overshoot).
cd "$(dirname "$0")/../.."
P="bash scripts/pg-local.sh psql -d salesos_test -q -At"
D=00000000-0000-0000-0000-0000000003a1; N=00000000-0000-0000-0000-0000000003b1
$P <<SQL >/dev/null
insert into dealers(id,name) values ('$D','Race Motors');
update dealer_settings set transactional_ignores_quiet = true where dealer_id='$D';
insert into channel_numbers(id,dealer_id,channel,address,activated_at,throttle_ms,jitter_max_ms) values ('$N','$D','sms','+15555559300', now(), 0, 0);  -- age 0 => cap 20
insert into contacts(id,dealer_id,first_name,phone_e164) select ('00000000-0000-0000-0000-00000003c0'||lpad(g::text,2,'0'))::uuid,'$D','R'||g,'+1555555'||(3000+g) from generate_series(1,30) g;
insert into consent_events(dealer_id,contact_id,channel,purpose,action,source) select '$D',id,'sms','transactional','grant','sms_keyword' from contacts where dealer_id='$D';
-- 18 slots used => 2 left
select can_send('$D', ('00000000-0000-0000-0000-00000003c0'||lpad(g::text,2,'0'))::uuid,'sms','transactional','transactional','$N','warm-up '||g||' '||md5(g::text)||md5((g*3)::text)||md5((g*5)::text),null,'system',false,true) from generate_series(1,18) g;
SQL
used() { $P -c "select count(*) from send_reservations where number_id='$N' and status='reserved'"; }
echo "reserved before race: $(used)"

call() { # $1 contact idx, $2 hold seconds
  $P <<SQL
begin;
select (can_send('$D', ('00000000-0000-0000-0000-00000003c0'||lpad('$1',2,'0'))::uuid,'sms','transactional','transactional','$N','race copy $1 '||md5('$1')||md5('x$1')||md5('y$1'),null,'system',false,true)).code;
select pg_sleep($2);
commit;
SQL
}
# --- serialization: A holds the lock ~1.5s; B must wait for it
s=$(date +%s.%N); call 19 1.5 > /tmp/a.out & PA=$!
sleep 0.4
sb=$(date +%s.%N); call 20 0 > /tmp/b.out; eb=$(date +%s.%N); wait $PA
waited=$(awk "BEGIN{printf \"%.2f\", $eb - $sb}")
echo "A: $(head -1 /tmp/a.out)   B: $(head -1 /tmp/b.out)   B waited ${waited}s for A's lock"
ok=1
awk "BEGIN{exit !($waited >= 0.9)}" || { echo "FAIL: B did not wait for the advisory lock"; ok=0; }

# --- cap race: now 20/20 used; free one slot, then race two committers for it
$P -c "update send_reservations set status='released' where id=(select id from send_reservations where number_id='$N' and status='reserved' order by reserved_at limit 1)" >/dev/null
echo "reserved before cap race: $(used) (cap 20)"
call 21 0.8 > /tmp/c.out & PC=$!
call 22 0.8 > /tmp/d.out & PD=$!
wait $PC $PD
echo "C: $(head -1 /tmp/c.out)  D: $(head -1 /tmp/d.out)"
allows=$(cat /tmp/c.out /tmp/d.out | grep -c '^reserved$')
caps=$(cat /tmp/c.out /tmp/d.out | grep -c '^daily_cap$')
[ "$allows" = 1 ] && [ "$caps" = 1 ] || { echo "FAIL: expected exactly one reserved and one daily_cap (got $allows/$caps)"; ok=0; }
echo "reserved after race: $(used)"
[ "$(used)" = 20 ] || { echo "FAIL: cap overshoot"; ok=0; }
[ $ok = 1 ] && echo "CONCURRENCY TESTS PASSED" || exit 1
