#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p certificates/ca certificates/bolt certificates/https

# --- SAN extension file (self-contained; cleaned up on exit) ---
SAN_EXTFILE="$(mktemp)"
trap 'rm -f "$SAN_EXTFILE"' EXIT
cat > "$SAN_EXTFILE" <<'EOF'
subjectAltName=DNS:localhost,IP:127.0.0.1
EOF

# --- Private CA ---
openssl genrsa -out certificates/ca/ca.key 4096
openssl req -x509 -new -nodes -key certificates/ca/ca.key -sha256 -days 3650 \
  -subj "/CN=Neo4j Local CA" -out certificates/ca/ca.crt

# --- Bolt cert ---
openssl genrsa -out certificates/bolt/private.key 4096
openssl req -new -key certificates/bolt/private.key -subj "/CN=neo4j" \
  -out certificates/bolt/bolt.csr
openssl x509 -req -in certificates/bolt/bolt.csr -CA certificates/ca/ca.crt \
  -CAkey certificates/ca/ca.key -CAcreateserial -days 825 \
  -extfile "$SAN_EXTFILE" \
  -out certificates/bolt/public.crt
rm -f certificates/bolt/bolt.csr

# --- HTTPS cert ---
openssl genrsa -out certificates/https/private.key 4096
openssl req -new -key certificates/https/private.key -subj "/CN=neo4j" \
  -out certificates/https/https.csr
openssl x509 -req -in certificates/https/https.csr -CA certificates/ca/ca.crt \
  -CAkey certificates/ca/ca.key -CAcreateserial -days 825 \
  -extfile "$SAN_EXTFILE" \
  -out certificates/https/public.crt
rm -f certificates/https/https.csr

chmod 600 certificates/ca/ca.key certificates/bolt/private.key certificates/https/private.key
echo "Certificates generated. Replace with a trusted CA cert for production."
