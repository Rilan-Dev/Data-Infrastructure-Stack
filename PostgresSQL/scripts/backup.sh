#!/usr/bin/env bash
# =============================================================================
# POSTGRES BACKUP SCRIPT — pg_dumpall for all databases
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
DEST="${POSTGRES_BACKUP_HOST:-./postgres/backups}"
RETENTION="${BACKUP_RETENTION_DAYS:-14}"

mkdir -p "$DEST"

# Full backup of all databases
# Note: pg_dumpall requires superuser privileges
# If you need to backup a single database, use pg_dump instead

echo "Creating full backup..."
docker exec postgres-db pg_dumpall -U "${POSTGRES_USER}" > "$DEST/full-$STAMP.sql"

echo "Created: full-$STAMP.sql"

# Prune old backups
echo "Pruning old backups (keep ${BACKUP_RETENTION_DAYS:-14})..."
ls -t "$DEST"/full-*.sql 2>/dev/null | tail -n +$((BACKUP_RETENTION_DAYS + 1)) | \
  while read OLD; do
    [ -n "$OLD" ] && rm -f "$OLD" && echo "Deleted $OLD"
  done

echo "Backup complete."
