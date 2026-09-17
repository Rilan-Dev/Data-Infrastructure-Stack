#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="backups/$STAMP"
mkdir -p "$DEST"
# The in-container neo4j user (uid 7474) must be able to write the .backup
# artifact, while the host user (uid 1000) writes verbose.log here. World-write
# on the timestamped dir is the minimal fix for this dual-owner bind mount.
chmod 777 "$DEST"

# Online (hot) backup against the running server via the backup service
# (server.backup.enabled=true, listening on 0.0.0.0:6362). Run as the in-container
# neo4j user so artifact ownership matches the database files.
docker exec -u neo4j neo4j neo4j-admin database backup neo4j \
  --to-path=/backups/$STAMP \
  --verbose >"$DEST/verbose.log" 2>&1

echo "Backup written to $DEST"
echo "REMINDER: copy $DEST off-host (object storage / remote host)."

# Local retention: delete backups older than 14 days.
find backups -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf {} +
echo "Old backups (>14 days) pruned locally."
