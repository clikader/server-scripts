#!/usr/bin/env bash
# Real service checks in a disposable Linux container. Never touches host config.
set -euo pipefail
name="clikader-integration-$RANDOM-$$"
root="$(cd "$(dirname "$0")/../.." && pwd)"
docker build -t clikader-integration -f tests/integration/Dockerfile tests/integration
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
docker run -d --name "$name" --privileged --cgroupns=private \
    --tmpfs /run --tmpfs /run/lock \
    -v "$root:/workspace/server-scripts:ro" clikader-integration
docker exec "$name" bash /workspace/server-scripts/tests/integration/check.sh
