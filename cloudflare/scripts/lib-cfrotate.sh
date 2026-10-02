#!/usr/bin/env bash
# lib-cfrotate.sh -- shared helpers for the Cloudflare API token rotation.
#
# SECURITY CONTRACT (read before editing):
#   * No function in this file may echo, log, or persist a credential value.
#   * Credentials are held in shell variables only, never in argv (argv is
#     world-readable via /proc/<pid>/cmdline).
#   * fingerprint() is the ONLY sanctioned way to refer to a credential in
#     output. It prints a truncated SHA-256, which is not reversible for a
#     high-entropy token.
#   * Callers must `set +x` around any region touching a value.

set -euo pipefail

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

CFR_RED=$'\033[31m'; CFR_YEL=$'\033[33m'; CFR_GRN=$'\033[32m'; CFR_DIM=$'\033[2m'; CFR_OFF=$'\033[0m'
[[ -t 1 ]] || { CFR_RED=""; CFR_YEL=""; CFR_GRN=""; CFR_DIM=""; CFR_OFF=""; }

log()  { printf '%s\n' "$*"; }
info() { printf '%s[ info ]%s %s\n' "$CFR_DIM" "$CFR_OFF" "$*"; }
ok()   { printf '%s[  ok  ]%s %s\n' "$CFR_GRN" "$CFR_OFF" "$*"; }
warn() { printf '%s[ warn ]%s %s\n' "$CFR_YEL" "$CFR_OFF" "$*" >&2; }
die()  { printf '%s[ FAIL ]%s %s\n' "$CFR_RED" "$CFR_OFF" "$*" >&2; exit 1; }
hdr()  { printf '\n=== %s ===\n' "$*"; }

# ---------------------------------------------------------------------------
# Credential fingerprinting
# ---------------------------------------------------------------------------

# fingerprint <value>
# Prints "sha256:<16 hex chars> len=<n>" -- safe to log, write to an issue, or
# commit. Never prints the value. An empty value is reported explicitly rather
# than as the well-known SHA-256 of the empty string, which has burned us
# before: e3b0c442... looks like a real fingerprint but means "nothing here".
fingerprint() {
  local v="${1-}"
  if [[ -z "$v" ]]; then
    printf '<empty/unset>'
    return 0
  fi
  printf 'sha256:%s len=%d' "$(printf '%s' "$v" | sha256sum | cut -c1-16)" "${#v}"
}

# same_value <a> <b> -- constant-ish comparison without echoing either side.
same_value() { [[ "${1-}" == "${2-}" ]]; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

require_cmds() {
  local missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  (( ${#missing[@]} == 0 )) || die "missing required commands: ${missing[*]}"
}

# ---------------------------------------------------------------------------
# Reading the new token from the sanctioned source
# ---------------------------------------------------------------------------

# read_token_from_paperclip <secret-path>
# Fetches a value from the Paperclip local encrypted secrets provider using the
# current run-bound agent JWT. Prints the value on stdout for capture via
# command substitution -- callers MUST assign it to a variable, never echo it.
read_token_from_paperclip() {
  local path="$1" base resp
  [[ -n "${PAPERCLIP_API_URL:-}" && -n "${PAPERCLIP_API_KEY:-}" ]] ||
    die "PAPERCLIP_API_URL / PAPERCLIP_API_KEY are not set; cannot reach the secrets provider"
  base="${PAPERCLIP_API_URL%/}"; base="${base%/api}"

  resp="$(curl -sS -X POST \
    -H "Authorization: Bearer $PAPERCLIP_API_KEY" \
    "$base/api/agents/me/secrets/$path/value" 2>/dev/null)" ||
    die "secrets provider request failed for '$path'"

  local val
  val="$(printf '%s' "$resp" | jq -r '.value // empty' 2>/dev/null)" || true
  [[ -n "$val" ]] || die "secrets provider returned no value for '$path' (is the access binding granted to this agent?)"
  printf '%s' "$val"
}

# read_token_from_file <path> -- for break-glass use when Paperclip is down.
read_token_from_file() {
  local f="$1"
  [[ -r "$f" ]] || die "token file not readable: $f"
  local mode; mode="$(stat -c '%a' "$f")"
  [[ "$mode" == "600" || "$mode" == "400" ]] ||
    die "token file $f has mode $mode; refusing to read a credential from a non-0600 file"
  tr -d '\r\n' < "$f"
}

# ---------------------------------------------------------------------------
# Consumer inspection
# ---------------------------------------------------------------------------

# container_env_value <container> <VAR> -- prints the value, or empty.
container_env_value() {
  local c="$1" v="$2"
  docker inspect "$c" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
    grep "^${v}=" | head -1 | cut -d= -f2- || true
}

container_exists()  { docker inspect "$1" >/dev/null 2>&1; }
container_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }

# container_health <container> -- "healthy" | "unhealthy" | "starting" | "none"
container_health() {
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || echo none
}

# wait_healthy <container> <timeout-seconds>
wait_healthy() {
  local c="$1" timeout="${2:-120}" waited=0 st
  while (( waited < timeout )); do
    st="$(container_health "$c")"
    case "$st" in
      healthy) return 0 ;;
      none)    container_running "$c" && return 0 || return 1 ;;
      unhealthy)
        # Docker reports unhealthy during the first failing probes after a
        # restart too, so keep waiting rather than failing on the first sample.
        : ;;
    esac
    sleep 3; waited=$(( waited + 3 ))
  done
  return 1
}
