#!/usr/bin/env bash
# Usage: bash bench/run.sh [local.py options]
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
workspace=$(dirname "$repo")
if [ "$#" -eq 0 ]; then
    set -- --rounds 3 --duration 8 --warmup 2 --output "/workspace/once-campfire-mojo/bench/results/$(date +%Y%m%d-%H%M%S)"
fi
docker run --rm --init --name campfire-local-benchmark \
    -v "$workspace:/workspace" \
    campfire-local-tools:latest \
    python3 /workspace/once-campfire-mojo/bench/local.py "$@"
