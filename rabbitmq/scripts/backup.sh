#!/usr/bin/env bash
# =============================================================================
# RABBITMQ BACKUP SCRIPT — exports definitions (queues, exchanges, bindings,
# users, permissions) via rabbitmqadmin. Message bodies are NOT backed up
# (RabbitMQ is a broker, not a durable data store) — only broker topology.
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ -f .env ]]; then
    set -a
    source .env
    set +a
fi

STAMP=$(date +%Y%m%d-%H%M%S)
DEST="${RABBITMQ_BACKUP_HOST:-./backup}"
RETENTION="${RABBITMQ_BACKUP_RETENTION:-14}"

mkdir -p "$DEST"

echo "Exporting RabbitMQ definitions..."
docker exec rabbitmq rabbitmqadmin export /tmp/definitions-export.json \
  --username="${RABBITMQ_ADMIN_USER}" --password="${RABBITMQ_ADMIN_PASSWORD}"
docker cp rabbitmq:/tmp/definitions-export.json "$DEST/definitions-$STAMP.json"
docker exec rabbitmq rm -f /tmp/definitions-export.json

echo "Created: definitions-$STAMP.json"

echo "Pruning old backups (keep ${RETENTION})..."
ls -t "$DEST"/definitions-*.json 2>/dev/null | tail -n +$((RETENTION + 1)) | \
  while read OLD; do
    [ -n "$OLD" ] && rm -f "$OLD" && echo "Deleted $OLD"
  done

echo "Backup complete."
