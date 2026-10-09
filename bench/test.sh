#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
workspace=$(dirname "$repo")
docker run --rm --init -v "$workspace:/workspace" \
    campfire-local-tools:latest \
    python3 /workspace/once-campfire-mojo/tests/integration.py
