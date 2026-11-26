#!/usr/bin/env bash
# Applies the migration to a fresh DB (twice) and runs every tests/sql/1*.sql file. Exit code != 0 on any failure.
cd "$(dirname "$0")/../.."
bash scripts/apply-migration.sh >/dev/null 2>&1 || { echo "migration failed"; bash scripts/apply-migration.sh 2>&1 | grep -E "ERROR" ; exit 1; }
P="bash scripts/pg-local.sh psql -d salesos_test -q"
$P -f tests/sql/01_helpers.sql >/dev/null
fail=0
for f in tests/sql/1*.sql; do
  out=$($P -f $f 2>&1)
  rc=$?
  oks=$(grep -c "NOTICE:  ok" <<<"$out")
  echo "### $f  rc=$rc  ok-checks=$oks"
  if [ $rc -ne 0 ]; then fail=1; grep -E "ERROR|FAIL|DETAIL|CONTEXT" <<<"$out" | head -8; fi
  grep -E "PASSED" <<<"$out"
done
exit $fail
