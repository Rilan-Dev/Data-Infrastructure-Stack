#!/usr/bin/env bash
# Lint and unit-test the Prometheus rule files.
#
# Runs promtool out of the same image the stack runs, so there is no host
# promtool install to keep in sync with the server version.
#
#   ./test-rules.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PROM_IMAGE="${PROM_IMAGE:-prom/prometheus:v3.5.0}"

run_promtool() {
  docker run --rm \
    -v "$ROOT/prometheus:/work:ro" \
    -w /work \
    --entrypoint promtool \
    "$PROM_IMAGE" "$@"
}

echo "== check config =="
run_promtool check config --syntax-only prometheus.yml

echo
echo "== check rules =="
run_promtool check rules rules/paperclip-identity.rules.yml rules/alerting-pipeline.rules.yml

echo
echo "== unit tests =="
run_promtool test rules tests/paperclip-identity.test.yml tests/alerting-pipeline.test.yml

echo
echo "all rule checks passed."
