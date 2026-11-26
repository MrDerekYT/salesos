#!/usr/bin/env bash
# Local throwaway Postgres 17 (+pgvector, +pg_cron) for verifying the migration. No root needed to run.
# usage: scripts/pg-local.sh start|stop|psql [args]
set -euo pipefail
BIN=/usr/lib/postgresql/17/bin
DATA=${PGDATA_DIR:-/workspace/pgdata-salesos}
PORT=${PGPORT_LOCAL:-54329}
case "${1:-}" in
  start)
    if [ ! -d "$DATA" ]; then
      $BIN/initdb -D "$DATA" -U postgres --auth=trust >/dev/null
      cat >> "$DATA/postgresql.conf" <<CONF
port = $PORT
unix_socket_directories = '/tmp'
listen_addresses = ''
CONF
      [ -z "${NO_CRON:-}" ] && printf "shared_preload_libraries = 'pg_cron'\ncron.database_name = 'salesos_test'\n" >> "$DATA/postgresql.conf"
    fi
    $BIN/pg_ctl -D "$DATA" -l "$DATA/server.log" -w start >/dev/null
    ;;
  stop) $BIN/pg_ctl -D "$DATA" -m fast stop ;;
  psql) shift; exec psql -h /tmp -p $PORT -U postgres -v ON_ERROR_STOP=1 "$@" ;;
esac
