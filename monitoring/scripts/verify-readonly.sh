#!/usr/bin/env bash
# Prove that paperclip_metrics_ro can do exactly one thing: SELECT from
# public.run_identity_contexts.
#
# Run after provision-metrics-role.sh, and again after any change to
# create-metrics-role.sql. This is the acceptance evidence for "exporter role
# verified to have no write access" — a GRANT that was never tested is not
# verified.
#
#   ./verify-readonly.sh
#
# The password is passed via a mode-600 PGPASSFILE in a temp dir, never via
# PGPASSWORD or argv, so it does not appear in `ps` output or the Docker daemon's
# command log.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$HERE/../.env}"
PG_NETWORK="${PG_NETWORK:-postgressql_postgres_network}"
PG_IMAGE="${PG_IMAGE:-pgvector/pgvector:pg16}"
PG_HOST="${PG_HOST:-postgres-db}"
PG_PORT="${PG_PORT:-5432}"
PG_DATABASE="${PG_DATABASE:-paperclip}"
ROLE="${ROLE:-paperclip_metrics_ro}"

[[ -f "$ENV_FILE" ]] || { echo "error: $ENV_FILE not found." >&2; exit 1; }
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a
[[ -n "${PAPERCLIP_EXPORTER_PASSWORD:-}" ]] || {
  echo "error: PAPERCLIP_EXPORTER_PASSWORD is empty in $ENV_FILE." >&2; exit 1; }

secrets_dir="$(mktemp -d)"
cleanup() { rm -rf "$secrets_dir"; }
trap cleanup EXIT
umask 077
printf '%s:%s:*:%s:%s\n' "$PG_HOST" "$PG_PORT" "$ROLE" "$PAPERCLIP_EXPORTER_PASSWORD" \
  >"$secrets_dir/pgpass"
chmod 600 "$secrets_dir/pgpass"

# Run a statement as the exporter role. Returns psql's exit status; stderr is
# captured so an expected-failure case can print the reason.
as_role() {
  local db="$1" sql="$2"
  docker run --rm -i \
    --network "$PG_NETWORK" \
    -v "$secrets_dir:/secrets:ro" \
    -e PGPASSFILE=/secrets/pgpass \
    -e PGCONNECT_TIMEOUT=10 \
    `# postgres-db currently emits a collation-version-mismatch WARNING on every` \
    `# connect to this database. Left alone it lands in the captured output and` \
    `# breaks the exact-match assertions below, so suppress notices/warnings and` \
    `# keep only the errors this script actually reasons about.` \
    -e PGOPTIONS="-c client_min_messages=error" \
    "$PG_IMAGE" \
    psql -X -q -t -A -v ON_ERROR_STOP=1 \
      -h "$PG_HOST" -p "$PG_PORT" -U "$ROLE" -d "$db" -c "$sql"
}

failures=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; failures=$((failures + 1)); }

expect_ok() {
  local label="$1" db="$2" sql="$3" out
  if out="$(as_role "$db" "$sql" 2>&1)"; then
    pass "$label${out:+ -> ${out//$'\n'/ }}"
  else
    fail "$label (expected success, got: ${out//$'\n'/ })"
  fi
}

expect_denied() {
  local label="$1" db="$2" sql="$3" out
  if out="$(as_role "$db" "$sql" 2>&1)"; then
    fail "$label (statement SUCCEEDED — the role has more privilege than intended)"
  elif grep -qiE 'permission denied|must be owner|does not exist' <<<"$out"; then
    pass "$label"
  else
    # Denied, but not for an authorization reason. Surface it rather than
    # counting a connection error as proof of least privilege.
    fail "$label (blocked for an unexpected reason: ${out//$'\n'/ })"
  fi
}

echo "verifying $ROLE against $PG_HOST:$PG_PORT/$PG_DATABASE"
echo
echo "1. the one thing it must be able to do"
expect_ok "SELECT on run_identity_contexts" "$PG_DATABASE" \
  "select count(*) from public.run_identity_contexts;"
expect_ok "the exporter's actual window query" "$PG_DATABASE" \
  "select count(*) from (select cause, coalesce(github->>'status','unknown') st, count(*)
     from public.run_identity_contexts
     where created_at > now() - interval '15 minutes' group by 1,2) q;"

echo
echo "2. no writes to the table it can read"
expect_denied "INSERT" "$PG_DATABASE" \
  "insert into public.run_identity_contexts (company_id, run_id, revision, cause, correlation_id)
     values (gen_random_uuid(), gen_random_uuid(), 1, 'verify', 'verify');"
expect_denied "UPDATE" "$PG_DATABASE" \
  "update public.run_identity_contexts set cause = 'verify';"
expect_denied "DELETE" "$PG_DATABASE" \
  "delete from public.run_identity_contexts;"
expect_denied "TRUNCATE" "$PG_DATABASE" \
  "truncate public.run_identity_contexts;"
expect_denied "ALTER TABLE" "$PG_DATABASE" \
  "alter table public.run_identity_contexts add column verify_probe int;"

echo
echo "3. no reach into the rest of the control plane"
expect_denied "SELECT on companies" "$PG_DATABASE" "select 1 from public.companies limit 1;"
expect_denied "SELECT on issues"    "$PG_DATABASE" "select 1 from public.issues limit 1;"
expect_denied "CREATE TABLE in public" "$PG_DATABASE" \
  "create table public.verify_probe (id int);"

echo
echo "4. no reach into other databases on the cluster"
# PostgreSQL grants CONNECT on most databases to PUBLIC and a per-role REVOKE
# does not override that, so the connection itself may succeed. What must hold
# is that the role can neither read nor create anything there.
expect_denied "CREATE TABLE in postgres db" "postgres" \
  "create table public.verify_probe (id int);"

echo
echo "5. no role-level privileges"
attrs="$(as_role "$PG_DATABASE" \
  "select format('super=%s create_db=%s create_role=%s replication=%s bypassrls=%s conn_limit=%s',
     rolsuper, rolcreatedb, rolcreaterole, rolreplication, rolbypassrls, rolconnlimit)
   from pg_roles where rolname = '$ROLE';" 2>/dev/null || true)"
if [[ "$attrs" == "super=f create_db=f create_role=f replication=f bypassrls=f conn_limit=4" ]]; then
  pass "role attributes: $attrs"
else
  fail "role attributes unexpected: $attrs"
fi

# Belt and braces: assert the grant list itself is exactly one SELECT.
grants="$(as_role "$PG_DATABASE" \
  "select coalesce(string_agg(distinct table_name || ':' || privilege_type, ', ' order by table_name || ':' || privilege_type), '(none)')
   from information_schema.table_privileges where grantee = '$ROLE';" 2>/dev/null || true)"
if [[ "$grants" == "run_identity_contexts:SELECT" ]]; then
  pass "table grants: $grants"
else
  fail "table grants should be exactly run_identity_contexts:SELECT, got: $grants"
fi

echo
if (( failures )); then
  echo "FAILED: $failures check(s) did not hold. Do not point the exporter at this role."
  exit 1
fi
echo "OK: $ROLE is read-only and scoped to public.run_identity_contexts."
