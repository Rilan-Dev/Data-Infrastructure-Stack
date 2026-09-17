#!/usr/bin/env bash
# =============================================================================
# REDIS RESTORE SCRIPT — Restore from RDB Snapshot
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
    set -a
    source .env
    set +a
fi

SNAPSHOT_FILE="${1:-}"
DEST="${REDIS_DATA_HOST:-./data}"

if [[ -z "$SNAPSHOT_FILE" ]]; then
    echo "Usage: $0 <snapshot-file>"
    echo "Available snapshots:"
    ls -la "${REDIS_SNAPSHOTS_HOST:-./snapshots}"/dump-*.rdb 2>/dev/null | awk '{print $9}'
    exit 1
fi

if [[ ! -f "$SNAPSHOT_FILE" ]]; then
    echo "Snapshot not found: $SNAPSHOT_FILE"
    exit 1
fi

echo "Stopping Redis..."
docker compose stop redis

echo "Restoring snapshot: $SNAPSHOT_FILE"
cp "$SNAPSHOT_FILE" "${DEST}/dump.rdb"

echo "Starting Redis..."
docker compose start redis

echo "Waiting for Redis to be healthy..."
for i in {1..30}; do
    if docker exec redis redis-cli -a "${REDIS_ADMIN_PASSWORD}" ping 2>/dev/null | grep -q PONG; then
        echo "Redis is healthy!"
        exit 0
    fi
    sleep 2
done

echo "ERROR: Redis did not become healthy in time"
exit 1
