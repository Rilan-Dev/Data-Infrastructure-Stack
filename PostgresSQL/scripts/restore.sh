#!/usr/bin/env bash
# =============================================================================
# POSTGRES RESTORE SCRIPT — restore from a pg_dumpall SQL backup
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

# Load environment
if [[ -f .env ]]; then
    set -a
    source .env
    set +a
fi

BACKUP_FILE="${1:-}"
DEST="${POSTGRES_BACKUP_HOST:-./postgres/backups}"

if [[ -z "$BACKUP_FILE" ]]; then
    echo "Usage: $0 <backup-file>"
    echo "Available backups:"
    ls -la "$DEST"/full-*.sql 2>/dev/null | awk '{print $9}'
    exit 1
fi

if [[ ! -f "$BACKUP_FILE" ]]; then
    echo "Error: backup file not found: $BACKUP_FILE"
    exit 1
fi

echo "WARNING: this will restore ALL databases from $BACKUP_FILE into the running"
echo "postgres-db container, potentially overwriting existing data."
read -p "Continue? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
fi

echo "Restoring from $BACKUP_FILE..."
cat "$BACKUP_FILE" | docker exec -i postgres-db psql -U "${POSTGRES_USER}" -d postgres

echo "Restore complete."
