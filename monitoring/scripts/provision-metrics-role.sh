#!/usr/bin/env bash
# Provision (or rotate the password of) the read-only exporter role.
#
#   ./provision-metrics-role.sh              # use the password already in .env
#   ./provision-metrics-role.sh --rotate     # generate a new password, rewrite .env
#
# The password is piped to psql over stdin, never passed as an argument, so it
# does not show up in `ps`, in the Docker daemon's command log, or in history.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${ENV_FILE:-$HERE/../.env}"
PG_CONTAINER="${PG_CONTAINER:-postgres-db}"
PG_SUPERUSER="${PG_SUPERUSER:-postgres}"
PG_DATABASE="${PG_DATABASE:-paperclip}"

rotate=0
[[ "${1:-}" == "--rotate" ]] && rotate=1

if [[ ! -f "$ENV_FILE" ]]; then
  echo "error: $ENV_FILE not found. Copy .env.example to .env first." >&2
  exit 1
fi

if [[ "$rotate" == "1" ]]; then
  # No pipeline here on purpose. The obvious `tr -dc ... </dev/urandom | head -c`
  # form makes `head` close the pipe on `tr`, and under `set -o pipefail` that
  # SIGPIPE becomes exit 141 — the script would die immediately after generating
  # a password it never stored. `openssl rand -hex` needs no pipe and is already
  # URI-safe, so the value drops into a DSN without escaping.
  new_password="$(openssl rand -hex 32)"
  new_password="${new_password:0:40}"
  tmp="$(mktemp)"
  chmod 600 "$tmp"
  # Replace the value without ever echoing it.
  PW="$new_password" awk '
    /^PAPERCLIP_EXPORTER_PASSWORD=/ { print "PAPERCLIP_EXPORTER_PASSWORD=" ENVIRON["PW"]; found = 1; next }
    { print }
    END { if (!found) print "PAPERCLIP_EXPORTER_PASSWORD=" ENVIRON["PW"] }
  ' "$ENV_FILE" >"$tmp"
  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "rotated PAPERCLIP_EXPORTER_PASSWORD in $ENV_FILE"
fi

# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

if [[ -z "${PAPERCLIP_EXPORTER_PASSWORD:-}" ]]; then
  echo "error: PAPERCLIP_EXPORTER_PASSWORD is empty in $ENV_FILE (run with --rotate)." >&2
  exit 1
fi

# Assemble the script in a mode-600 temp file and feed it in by redirection
# rather than through a pipe. `docker exec -i` stops reading stdin the moment
# psql exits, which makes the writing end of a pipe take SIGPIPE and the whole
# pipeline exit 141 even on a fully successful run. Redirection has no writer to
# kill, so the exit status actually means something.
sql_file="$(mktemp)"
chmod 600 "$sql_file"
cleanup() { rm -f "$sql_file"; }
trap cleanup EXIT

{
  # psql's :'var' form emits a correctly escaped SQL literal.
  printf "\\set role_password '%s'\n" "${PAPERCLIP_EXPORTER_PASSWORD//\'/\'\'}"
  cat "$HERE/create-metrics-role.sql"
} >"$sql_file"

docker exec -i "$PG_CONTAINER" \
  psql -X -q -v ON_ERROR_STOP=1 -U "$PG_SUPERUSER" -d "$PG_DATABASE" -f - \
  <"$sql_file"

echo "done. Now run ./verify-readonly.sh to prove the grant is read-only."
