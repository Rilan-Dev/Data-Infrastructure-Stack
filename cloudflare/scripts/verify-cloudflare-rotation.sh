#!/usr/bin/env bash
#
# verify-cloudflare-rotation.sh -- prove the estate is healthy, and compare
# against the pre-rotation baseline so that pre-existing faults are not
# mistaken for rotation damage.
#
#   ./verify-cloudflare-rotation.sh --baseline        # record a new baseline
#   ./verify-cloudflare-rotation.sh                   # verify against baseline
#
# Exit codes: 0 = no regression vs baseline, 1 = regression detected.
#
# This script makes no authenticated Cloudflare API calls and needs no
# credential. It checks reachability, which is what actually matters to users.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-cfrotate.sh
source "$SCRIPT_DIR/lib-cfrotate.sh"

BASELINE_FILE="${CF_BASELINE_FILE:-$SCRIPT_DIR/../baseline/hostnames.tsv}"
MODE="verify"
[[ "${1:-}" == "--baseline" ]] && MODE="baseline"

require_cmds curl systemctl docker

HOSTS=(
  nexahub auth platform pro-rilan default api-nexahub
  jenkins n8n dynamic-ui talentbridge
  dur obsidian api-obsidian api-dynoshopcy api-equitenant
  camofox-api camofox-vnc camofox-cp openclaw
)
DOMAIN="ostechnologies.in"

probe() {
  local fq="$1"
  timeout 20 curl -s -o /dev/null -w '%{http_code}' -L --max-time 15 "https://$fq/" 2>/dev/null || echo "000"
}

# ---------------------------------------------------------------------------
# 1. Tunnel health (the thing an API-token swap must NOT disturb)
# ---------------------------------------------------------------------------

hdr "Cloudflare Tunnel"
state="$(systemctl is-active cloudflared 2>/dev/null || true)"
if [[ "$state" == "active" ]]; then ok "cloudflared.service is active"; else die "cloudflared.service is $state"; fi

ready="$(timeout 10 curl -s --max-time 8 http://127.0.0.1:20241/ready 2>/dev/null || true)"
if [[ -n "$ready" ]]; then
  conns="$(printf '%s' "$ready" | jq -r '.readyConnections // 0' 2>/dev/null || echo 0)"
  if (( conns >= 1 )); then ok "tunnel has $conns ready edge connections"
  else warn "tunnel reports $conns ready connections"; fi
else
  warn "tunnel /ready endpoint did not answer on 127.0.0.1:20241 (metrics may be bound elsewhere)"
fi

# ---------------------------------------------------------------------------
# 2. Hostname reachability
# ---------------------------------------------------------------------------

hdr "Public hostnames"
results=""
for h in "${HOSTS[@]}"; do
  fq="$h.$DOMAIN"
  code="$(probe "$fq")"
  results+="$fq	$code"$'\n'
  printf '%-34s %s\n' "$fq" "$code"
done

if [[ "$MODE" == "baseline" ]]; then
  mkdir -p "$(dirname "$BASELINE_FILE")"
  { printf '# Cloudflare hostname baseline\n# captured: %s\n' "$(date -u +%FT%TZ)"
    printf '%s' "$results"; } > "$BASELINE_FILE"
  ok "baseline written to $BASELINE_FILE"
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. Regression comparison
# ---------------------------------------------------------------------------

hdr "Comparison against baseline"
[[ -f "$BASELINE_FILE" ]] || die "no baseline at $BASELINE_FILE -- run with --baseline first"

regressions=0
while IFS=$'\t' read -r fq code; do
  [[ -z "$fq" || "$fq" == \#* ]] && continue
  base="$(awk -F'\t' -v h="$fq" '$1==h {print $2}' "$BASELINE_FILE")"
  if [[ -z "$base" ]]; then
    warn "$fq is not in the baseline (new hostname?)"
    continue
  fi
  # A host that was already failing before rotation is not a regression.
  if [[ "$base" == "$code" ]]; then
    continue
  fi
  if [[ "$base" =~ ^(2|3) && ! "$code" =~ ^(2|3) ]]; then
    printf '%s[ REGRESSION ]%s %-34s %s -> %s\n' "$CFR_RED" "$CFR_OFF" "$fq" "$base" "$code"
    regressions=$(( regressions + 1 ))
  else
    info "$fq changed $base -> $code (not a regression)"
  fi
done <<<"$results"

hdr "Result"
if (( regressions == 0 )); then
  ok "no regressions against baseline -- rotation is clean"
  exit 0
fi
printf '%s%d regression(s) detected -- roll back with rotate-cloudflare-token.sh --rollback <id>%s\n' "$CFR_RED" "$regressions" "$CFR_OFF" >&2
exit 1
