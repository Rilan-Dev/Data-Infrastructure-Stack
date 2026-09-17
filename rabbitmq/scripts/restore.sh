#!/usr/bin/env bash
# =============================================================================
# RABBITMQ RESTORE SCRIPT — imports a definitions JSON export (queues,
# exchanges, bindings, users, permissions) via rabbitmqadmin.
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
    set -a
    source .env
    set +a
fi

BACKUP_FILE="${1:-}"
DEST="${RABBITMQ_BACKUP_HOST:-./backup}"

if [[ -z "$BACKUP_FILE" ]]; then
    echo "Usage: $0 <definitions-file.json>"
    echo "Available backups:"
    ls -la "$DEST"/definitions-*.json 2>/dev/null | awk '{print $9}'
    exit 1
fi

if [[ ! -f "$BACKUP_FILE" ]]; then
    echo "Error: backup file not found: $BACKUP_FILE"
    exit 1
fi

echo "Restoring definitions from $BACKUP_FILE into the running rabbitmq container..."
docker cp "$BACKUP_FILE" rabbitmq:/tmp/definitions-import.json
docker exec rabbitmq rabbitmqadmin import /tmp/definitions-import.json \
  --username="${RABBITMQ_ADMIN_USER}" --password="${RABBITMQ_ADMIN_PASSWORD}"
docker exec rabbitmq rm -f /tmp/definitions-import.json

echo "Restore complete."
