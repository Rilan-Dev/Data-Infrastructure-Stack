#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

# Create persistent dirs.
mkdir -p data logs import plugins backups
touch import/.gitkeep plugins/.gitkeep

# Create secret if missing.
if [ ! -f secrets/neo4j_auth ]; then
  mkdir -p secrets
  PASS="$(openssl rand -base64 48)"
  printf 'neo4j/%s\n' "$PASS" > secrets/neo4j_auth
  chmod 600 secrets/neo4j_auth
  echo "Secret created at secrets/neo4j_auth"
fi

# Generate certs if missing.
if [ ! -f certificates/bolt/public.crt ]; then
  bash scripts/generate-certs.sh
fi

# Pull pinned image.
docker compose pull

# Start.
docker compose up -d
echo "Neo4j starting. Check health: docker compose ps"
