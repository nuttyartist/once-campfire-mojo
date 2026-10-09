#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
workspace=$(dirname "$repo")
output=${1:-bench/results/$(date +%Y-%m-%d)-durable}
docker run --rm --init -v "$workspace:/workspace" -w /workspace/once-campfire-mojo "${TOOLCHAIN_IMAGE:-campfire-local-tools:verified}" python3 bench/durable.py --output "$output"
