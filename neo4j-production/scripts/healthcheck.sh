#!/usr/bin/env bash
set -euo pipefail
curl --insecure --fail --silent --output /dev/null https://0.0.0.0:7473/ \
  || exit 1
