#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
BACKUP="${1:-}"
if [ -z "$BACKUP" ] || [ ! -d "backups/$BACKUP" ]; then
  echo "Usage: $0 <backup-directory>"
  echo "e.g. $0 20260816-123456"
  exit 1
fi

echo "This will OVERWRITE the current database. Type RESTORE to continue:"
read -r CONFIRM
if [ "$CONFIRM" != "RESTORE" ]; then
  echo "Aborted."
  exit 1
fi

docker stop neo4j
docker run --rm \
  -v neo4j-production_data:/data \
  -v "$(pwd)/backups/$BACKUP":/backup:ro \
  -e NEO4J_AUTH=none \
  "${NEO4J_IMAGE:-neo4j:2026.06.0-enterprise}" \
  neo4j-admin database restore --from-path=/backup \
  --to-path=/data/databases --overwrite-destination
docker start neo4j
echo "Restore complete."
