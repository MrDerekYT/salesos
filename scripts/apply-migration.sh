#!/usr/bin/env bash
# Creates a fresh DB, installs the Supabase shim, applies the migration (twice, to prove idempotency).
set -euo pipefail
cd "$(dirname "$0")/.."
DB=${1:-salesos_test}
P="bash scripts/pg-local.sh psql -v ON_ERROR_STOP=1"
$P -d postgres -qc "drop database if exists $DB with (force)" -c "create database $DB"
$P -d $DB -q -f tests/sql/00_supabase_shim.sql
for m in supabase/migrations/*.sql; do $P -d $DB -q -f "$m"; done
echo "== applied once"
for m in supabase/migrations/*.sql; do $P -d $DB -q -f "$m"; done
echo "== applied twice (idempotent)"
