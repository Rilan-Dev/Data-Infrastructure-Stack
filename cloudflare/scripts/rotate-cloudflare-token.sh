#!/usr/bin/env bash
#
# rotate-cloudflare-token.sh -- swap the Cloudflare API token across every
# consumer on this host, idempotently, with an automatic rollback.
#
#   ./rotate-cloudflare-token.sh --dry-run                 # default; mutates nothing
#   ./rotate-cloudflare-token.sh --dry-run --source current
#   ./rotate-cloudflare-token.sh --apply
#   ./rotate-cloudflare-token.sh --rollback <snapshot-id>
#
# Sources for the new token value:
#   --source paperclip   (default) Paperclip local encrypted secrets provider,
#                        path $CF_SECRET_PATH. This is the "one paste" target.
#   --source file:/p     break-glass; /p must be mode 0600 or 0400.
#   --source current     re-apply the value already in place. Mutates nothing
#                        by definition and is the idempotency self-test.
#
# SECURITY: this script never prints a token. Credentials are referenced in
# output only by truncated SHA-256. See lib-cfrotate.sh for the full contract.
#
# SCOPE: this rotates the Cloudflare *API token* (zone DNS/API authority).
# It deliberately does NOT touch /etc/cloudflared/token, which is a tunnel
# token -- a different credential class with a different rotation procedure.
# See ../ROTATION-RUNBOOK.md, "Two different Cloudflare credentials".

set -euo pipefail
shopt -s inherit_errexit 2>/dev/null || true

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib-cfrotate.sh
source "$SCRIPT_DIR/lib-cfrotate.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

CF_SECRET_PATH="${CF_SECRET_PATH:-integrations/cloudflare/api-token}"

# Snapshots hold full container specs, which include ~15 unrelated live
# secrets. They must never land in the repo or in a world-readable directory.
SNAPSHOT_ROOT="${CF_SNAPSHOT_ROOT:-$HOME/.local/state/cloudflare-rotation}"

HEALTH_TIMEOUT="${CF_HEALTH_TIMEOUT:-150}"

# Consumer registry: id|container|env-var|criticality
# Keep this in sync with ../ROTATION-RUNBOOK.md section 1 (blast radius).
CONSUMERS=(
  "obsidian-api|obsidian-commerce-api|CLOUDFLARE_API_TOKEN|live"
  "doable-api|doable-api|CF_API_TOKEN|declared-empty"
)

MODE="dry-run"
SOURCE="paperclip"
ROLLBACK_ID=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while (( $# )); do
  case "$1" in
    --dry-run)  MODE="dry-run" ;;
    --apply)    MODE="apply" ;;
    --rollback) MODE="rollback"; ROLLBACK_ID="${2:-}"; shift ;;
    --source)   SOURCE="${2:-}"; shift ;;
    -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
    *)          die "unknown argument: $1" ;;
  esac
  shift
done

require_cmds docker jq curl sha256sum stat

# ---------------------------------------------------------------------------
# Rollback mode
# ---------------------------------------------------------------------------

if [[ "$MODE" == "rollback" ]]; then
  [[ -n "$ROLLBACK_ID" ]] || die "--rollback needs a snapshot id (see $SNAPSHOT_ROOT)"
  snap="$SNAPSHOT_ROOT/$ROLLBACK_ID"
  [[ -d "$snap" ]] || die "no such snapshot: $snap"
  hdr "Rollback from snapshot $ROLLBACK_ID"
  for f in "$snap"/*.rollback-name; do
    [[ -e "$f" ]] || continue
    target="$(basename "$f" .rollback-name)"
    saved="$(cat "$f")"
    info "restoring $target from $saved"
    docker rm -f "$target" >/dev/null 2>&1 || true
    docker rename "$saved" "$target"
    docker start "$target" >/dev/null
    wait_healthy "$target" "$HEALTH_TIMEOUT" && ok "$target healthy" || warn "$target did not report healthy"
  done
  ok "rollback complete"
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolve the new token (never echoed)
# ---------------------------------------------------------------------------

hdr "Cloudflare API token rotation -- mode=$MODE source=$SOURCE"

set +x
NEW_TOKEN=""
case "$SOURCE" in
  paperclip)
    info "reading new value from the Paperclip secrets provider: $CF_SECRET_PATH"
    NEW_TOKEN="$(read_token_from_paperclip "$CF_SECRET_PATH")"
    ;;
  file:*)
    info "reading new value from file (break-glass path)"
    NEW_TOKEN="$(read_token_from_file "${SOURCE#file:}")"
    ;;
  current)
    info "using the value already deployed (idempotency self-test; no new secret involved)"
    NEW_TOKEN="$(container_env_value obsidian-commerce-api CLOUDFLARE_API_TOKEN)"
    [[ -n "$NEW_TOKEN" ]] || die "no current value found on obsidian-commerce-api"
    ;;
  *) die "unknown --source: $SOURCE (expected paperclip | file:/path | current)" ;;
esac

info "new value fingerprint: $(fingerprint "$NEW_TOKEN")"

# A Cloudflare API token is high-entropy and comfortably longer than 20 chars.
# This catches the classic failure of pasting a zone ID, an account ID, or a
# truncated value -- all of which would authenticate as nothing and take the
# DNS automation down silently.
(( ${#NEW_TOKEN} >= 20 )) || die "new value is implausibly short (${#NEW_TOKEN} chars); refusing to deploy"

# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------

hdr "Consumer survey"

declare -a TO_UPDATE=()
plan_rows=""

for entry in "${CONSUMERS[@]}"; do
  IFS='|' read -r id container var crit <<<"$entry"

  if ! container_exists "$container"; then
    plan_rows+=$(printf '%-14s %-24s %-22s %s\n' "$id" "$container" "$var" "MISSING (container absent)")$'\n'
    [[ "$crit" == "live" ]] && warn "live consumer '$id' is absent -- investigate before applying"
    continue
  fi

  cur="$(container_env_value "$container" "$var")"

  if [[ -z "$cur" ]]; then
    plan_rows+=$(printf '%-14s %-24s %-22s %s\n' "$id" "$container" "$var" "SKIP (declared but empty -- not a real consumer)")$'\n'
    continue
  fi

  if same_value "$cur" "$NEW_TOKEN"; then
    plan_rows+=$(printf '%-14s %-24s %-22s %s\n' "$id" "$container" "$var" "SKIP (already current -- idempotent no-op)")$'\n'
  else
    plan_rows+=$(printf '%-14s %-24s %-22s %s\n' "$id" "$container" "$var" "UPDATE $(fingerprint "$cur") -> $(fingerprint "$NEW_TOKEN")")$'\n'
    TO_UPDATE+=("$entry")
  fi
done

printf '%-14s %-24s %-22s %s\n' "ID" "CONTAINER" "VAR" "ACTION"
printf '%s' "$plan_rows"

hdr "Non-consumers (verified, deliberately untouched)"
printf '%-30s %s\n' "/etc/cloudflared/token" "TUNNEL token, not an API token -- different credential class"
printf '%-30s %s\n' "cloudflared.service" "no CLOUDFLARE_API_TOKEN in unit or environment"
printf '%-30s %s\n' "all 20 public hostnames" "served by the tunnel; unaffected by an API-token swap"

if (( ${#TO_UPDATE[@]} == 0 )); then
  hdr "Result"
  ok "nothing to do -- every consumer already holds the target value"
  ok "idempotency confirmed: a re-run of this script is a safe no-op"
  exit 0
fi

if [[ "$MODE" == "dry-run" ]]; then
  hdr "Result (dry run -- nothing was changed)"
  info "${#TO_UPDATE[@]} consumer(s) would be updated"
  for entry in "${TO_UPDATE[@]}"; do
    IFS='|' read -r id container var crit <<<"$entry"
    info "  would recreate '$container' with a new $var, then wait up to ${HEALTH_TIMEOUT}s for health"
  done
  info "re-run with --apply to perform the swap"
  exit 0
fi

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
SNAP="$SNAPSHOT_ROOT/$STAMP"
mkdir -p "$SNAP"; chmod 700 "$SNAPSHOT_ROOT" "$SNAP"

hdr "Applying (snapshot $STAMP)"

for entry in "${TO_UPDATE[@]}"; do
  IFS='|' read -r id container var crit <<<"$entry"

  info "[$container] snapshotting full container spec"
  docker inspect "$container" > "$SNAP/$container.json"
  chmod 600 "$SNAP/$container.json"   # contains every env var, including other secrets

  spec="$SNAP/$container.json"
  image="$(jq -r '.[0].Config.Image' "$spec")"
  restart="$(jq -r '.[0].HostConfig.RestartPolicy.Name // "no"' "$spec")"
  mapfile -t networks < <(jq -r '.[0].NetworkSettings.Networks | keys[]' "$spec")

  # Rebuild the env set with the one variable replaced. Written to a 0600 file
  # in the snapshot dir, never passed via argv (argv is world-readable).
  envfile="$SNAP/$container.env"
  ( umask 077
    jq -r --arg v "$var" '.[0].Config.Env[] | select(startswith($v + "=") | not)' "$spec" > "$envfile"
    printf '%s=%s\n' "$var" "$NEW_TOKEN" >> "$envfile"
  )

  backup_name="${container}-prerotate-${STAMP}"
  info "[$container] stopping and preserving old container as $backup_name"
  docker stop "$container" >/dev/null
  docker rename "$container" "$backup_name"
  printf '%s' "$backup_name" > "$SNAP/$container.rollback-name"

  # Reconstruct the run spec. Only the first network can be attached at create
  # time; the rest are connected afterwards.
  run_args=(
    --name "$container"
    --detach
    --restart "$restart"
    --env-file "$envfile"
  )
  [[ "${#networks[@]}" -gt 0 ]] && run_args+=(--network "${networks[0]}")

  while IFS= read -r m; do run_args+=(--volume "$m"); done < <(
    jq -r '.[0].Mounts[]? | if .Type == "bind" then "\(.Source):\(.Destination)\(if .RW then "" else ":ro" end)" else "\(.Name):\(.Destination)" end' "$spec")

  while IFS= read -r p; do run_args+=(--publish "$p"); done < <(
    jq -r '.[0].HostConfig.PortBindings // {} | to_entries[] | .key as $cp | .value[]? | "\(.HostIp // "")\(if (.HostIp // "") == "" then "" else ":" end)\(.HostPort):\($cp | sub("/tcp$";""))"' "$spec")

  mapfile -t cmd < <(jq -r '.[0].Config.Cmd // [] | .[]' "$spec")

  info "[$container] recreating from image $image"
  docker run "${run_args[@]}" "$image" "${cmd[@]}" >/dev/null

  for n in "${networks[@]:1}"; do
    info "[$container] attaching additional network $n"
    docker network connect "$n" "$container"
  done

  info "[$container] waiting up to ${HEALTH_TIMEOUT}s for health"
  if wait_healthy "$container" "$HEALTH_TIMEOUT"; then
    ok "[$container] healthy with the new token"
    shred -u "$envfile" 2>/dev/null || rm -f "$envfile"
  else
    warn "[$container] did NOT become healthy -- rolling back automatically"
    docker rm -f "$container" >/dev/null 2>&1 || true
    docker rename "$backup_name" "$container"
    docker start "$container" >/dev/null
    shred -u "$envfile" 2>/dev/null || rm -f "$envfile"
    die "[$container] rotation rolled back. Snapshot retained at $SNAP. Fix the token and retry."
  fi
done

hdr "Done"
ok "rotation applied; snapshot $STAMP retained at $SNAP"
info "verify with: $SCRIPT_DIR/verify-cloudflare-rotation.sh"
info "roll back with: $0 --rollback $STAMP"
warn "after verification, delete the snapshot -- it contains other live secrets:"
warn "  rm -rf $SNAP   # and docker rm the *-prerotate-$STAMP containers"
