#!/usr/bin/env bash
# =============================================================================
# REDIS BACKUP SCRIPT — Manual/Scheduled RDB Snapshot
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

# Load environment
if [[ -f .env ]]; then
    set -a
    source .env
    set +a
fi

STAMP=$(date +%Y%m%d-%H%M%S)
DEST="${REDIS_SNAPSHOTS_HOST:-/docker/redis/snapshots}"
RETENTION="${REDIS_SNAPSHOT_RETENTION:-7}"

mkdir -p "$DEST"

echo "Creating RDB snapshot..."
docker exec redis redis-cli -a "${REDIS_ADMIN_PASSWORD}" --rdb "/snapshots/dump-${STAMP}.rdb"

echo "Created: dump-${STAMP}.rdb"

# Prune old snapshots
echo "Pruning old snapshots (keep ${REDIS_SNAPSHOT_RETENTION:-7})..."
ls -t "${DEST}"/dump-*.rdb 2>/dev/null | tail -n +$((REDIS_SNAPSHOT_RETENTION + 1)) | \
  while read OLD; do
    [ -n "$OLD" ] && rm -f "$OLD" && echo "Deleted $OLD"
  done

echo "Backup complete."
