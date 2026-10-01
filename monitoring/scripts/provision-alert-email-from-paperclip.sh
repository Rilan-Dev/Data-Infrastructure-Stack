#!/usr/bin/env bash
# Provision the Alertmanager SMTP credential from a Paperclip-granted secret.
#
#   ./provision-alert-email-from-paperclip.sh [secret-key]
#
# Default secret key: resend_alerts_api_key
#
# WHY THIS EXISTS
# The Resend API key for platform alerting is held by the board, not by this
# host. The obvious handoff -- a human pastes the key into an issue comment or a
# chat message -- puts a live sending credential into an audit log that many
# principals can read, forever. This script closes that gap: the board stores
# the key once as a Paperclip secret granted to the DevOps agent, and the value
# travels API -> memory -> mode-600 file without ever being echoed, logged, or
# written into a comment, a document, or shell history.
#
# Requires the current run-bound agent JWT (PAPERCLIP_API_KEY). Long-lived agent
# keys and low-trust tokens are denied by the secrets API by design.
#
# Every fetch is audited server-side in secret_access_events and activity_log.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRET_KEY="${1:-resend_alerts_api_key}"

: "${PAPERCLIP_API_URL:?PAPERCLIP_API_URL is not set -- run this inside a Paperclip agent run}"
: "${PAPERCLIP_API_KEY:?PAPERCLIP_API_KEY is not set -- run this inside a Paperclip agent run}"

API_BASE="${PAPERCLIP_API_URL%/}"
API_BASE="${API_BASE%/api}"

echo "fetching granted secret \"$SECRET_KEY\" ..."

# -f so a 401/403/404 is a failure, not an empty "success". The body is captured
# to a variable rather than a file so the value never lands on disk unencrypted.
http_body=""
http_code=""
if ! http_body="$(curl -sS -w $'\n%{http_code}' -X POST \
      -H "Authorization: Bearer $PAPERCLIP_API_KEY" \
      "$API_BASE/api/agents/me/secrets/$SECRET_KEY/value")"; then
  echo "error: request to the Paperclip secrets API failed." >&2
  exit 1
fi
http_code="${http_body##*$'\n'}"
http_body="${http_body%$'\n'*}"

if [[ "$http_code" != "200" ]]; then
  # Print the status and the error name, never the body verbatim -- on some
  # error paths the body can echo request context.
  reason="$(printf '%s' "$http_body" | python3 -c \
    'import json,sys
try:
    d = json.load(sys.stdin)
    print(d.get("error") or d.get("message") or d.get("name") or "unknown")
except Exception:
    print("unparseable response")' 2>/dev/null || echo "unknown")"
  echo "error: secrets API returned HTTP $http_code ($reason)." >&2
  echo >&2
  case "$http_code" in
    403|404) echo "Most likely the secret \"$SECRET_KEY\" is not granted to this" >&2
             echo "agent yet -- the board must create it and bind it to the DevOps" >&2
             echo "agent. Confirm what this run can see with:" >&2
             echo "  curl -s -H \"Authorization: Bearer \$PAPERCLIP_API_KEY\" \\" >&2
             echo "    \"\$PAPERCLIP_API_URL/agents/me/secrets\"" >&2
             echo "Otherwise the token itself cannot read secrets: the secrets API" >&2
             echo "requires the run-bound agent JWT and denies long-lived keys." >&2 ;;
    401) echo "Token rejected. The secrets API requires the run-bound agent JWT." >&2 ;;
  esac
  exit 1
fi

# Extract into the environment of the downstream script only. Never echoed.
export ALERT_SMTP_PASSWORD
ALERT_SMTP_PASSWORD="$(printf '%s' "$http_body" | python3 -c \
  'import json,sys
v = json.load(sys.stdin).get("value")
if not v:
    sys.exit("secrets API response contained no value")
sys.stdout.write(v)')"

if [[ -z "$ALERT_SMTP_PASSWORD" ]]; then
  echo "error: granted secret \"$SECRET_KEY\" is empty." >&2
  exit 1
fi

echo "fetched (${#ALERT_SMTP_PASSWORD} bytes). Handing off to provision-alert-email.sh ..."
echo

# provision-alert-email.sh preflights the key against smtp.resend.com before it
# writes anything, so a wrong-account or revoked key is rejected here.
"$HERE/provision-alert-email.sh" --from-env
rc=$?
unset ALERT_SMTP_PASSWORD

exit "$rc"
