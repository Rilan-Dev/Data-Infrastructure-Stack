#!/usr/bin/env bash
# Write the Alertmanager SMTP password into alertmanager/secrets/smtp_password.
#
# Alertmanager does not expand environment variables in its config, so the
# credential has to reach it as a file. Keeping it in a file (rather than inline
# in alertmanager.yml) is what makes alertmanager.yml committable.
#
#   ./provision-alert-email.sh                 # read the key from stdin (no echo)
#   ALERT_SMTP_PASSWORD=... ./provision-alert-email.sh --from-env
#
# The key is never passed as an argument, so it stays out of `ps` and history.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRET_DIR="${SECRET_DIR:-$HERE/../alertmanager/secrets}"
SECRET_FILE="$SECRET_DIR/smtp_password"

mkdir -p "$SECRET_DIR"
chmod 700 "$SECRET_DIR"

if [[ "${1:-}" == "--from-env" ]]; then
  : "${ALERT_SMTP_PASSWORD:?set ALERT_SMTP_PASSWORD when using --from-env}"
  key="$ALERT_SMTP_PASSWORD"
else
  read -rsp "Resend API key (input hidden): " key
  echo
fi

if [[ -z "$key" ]]; then
  echo "error: empty key. Alertmanager would accept alerts and deliver none." >&2
  exit 1
fi

umask 077
printf '%s' "$key" >"$SECRET_FILE"
chmod 600 "$SECRET_FILE"

echo "wrote $SECRET_FILE (mode 600, ${#key} bytes)"
echo
echo "Reload Alertmanager so it picks the new credential up:"
echo "  docker compose -f \"$HERE/../docker-compose.yml\" restart alertmanager"
echo
echo "Then send a test alert and confirm it arrives:"
echo "  ./send-test-alert.sh"
