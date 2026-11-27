#!/usr/bin/env bash
# CI/throwaway only: creates a fresh DB, installs the Supabase shim, applies supabase/migrations in order.
# Derek's live salesos history is applied once (it is not idempotent); the salesos_ai migrations are applied twice
# to prove they are idempotent. pg_net is skipped when the CI Postgres does not ship it (invoke_edge_function no-ops).
set -euo pipefail
cd "$(dirname "$0")/.."
DB=${1:-salesos_test}
P="bash scripts/pg-local.sh psql -v ON_ERROR_STOP=1"
$P -d postgres -qc "drop database if exists $DB with (force)" -c "create database $DB"
$P -d postgres -qc "alter database $DB set search_path = salesos_ai, public, extensions"
$P -d $DB -q -f tests/sql/00_supabase_shim.sql
HAS_NET=$($P -d $DB -At -c "select count(*) from pg_available_extensions where name = 'pg_net'")
apply() {
  if [ "$HAS_NET" = "0" ]; then sed 's/^create extension if not exists pg_net with schema extensions;/-- pg_net unavailable in CI/' "$1" | $P -d $DB -q
  else $P -d $DB -q -f "$1"; fi
}
for m in supabase/migrations/*.sql; do apply "$m"; done
echo "== applied once"
for m in supabase/migrations/*_salesos_ai_*.sql; do apply "$m"; done
echo "== salesos_ai applied twice (idempotent)"
