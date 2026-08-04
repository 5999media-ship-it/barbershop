#!/usr/bin/env bash
# =============================================================================
# Draait alle migraties + tests op een lokale, kale Postgres 16.
# Bedoeld als snelle regressietest zonder Supabase-account.
#
#   ./supabase/tests/run.sh
#
# Vereist: postgresql-16 + postgresql-contrib-16, een draaiende server, en
# de omgevingsvariabelen PGHOST/PGPORT/PGUSER.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DB="${DB:-bbtest}"

export PGHOST="${PGHOST:-/tmp}"
export PGPORT="${PGPORT:-5433}"
export PGUSER="${PGUSER:-postgres}"

echo "==> Database $DB opnieuw opbouwen"
dropdb --if-exists "$DB"
createdb "$DB"

psql -X -q -d "$DB" -v ON_ERROR_STOP=1 -f "$ROOT/supabase/tests/00_supabase_stub.sql" >/dev/null

echo "==> Migraties draaien"
for f in "$ROOT"/supabase/migrations/*.sql; do
  printf '    %s\n' "$(basename "$f")"
  psql -X -q -d "$DB" -v ON_ERROR_STOP=1 -f "$f" 2>&1 | grep -v 'NOTICE' || true
done

echo "==> Tests draaien"
for t in "$ROOT"/supabase/tests/0[12]_*.sql; do
  psql -X -q -d "$DB" -v ON_ERROR_STOP=1 -f "$t" 2>&1 \
    | sed -E 's/^psql:[^ ]+ //; s/^NOTICE:  //' \
    | grep -v '^SET$\|^RESET$\|^DO$\|^INSERT \|^UPDATE \|^DELETE '
done
