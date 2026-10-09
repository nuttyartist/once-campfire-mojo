#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
workspace=$(dirname "$repo")
docker run --rm --init -v "$workspace:/workspace" \
    -w /workspace/once-campfire-mojo "${TOOLCHAIN_IMAGE:-campfire-local-tools:latest}" \
    bash -c 'make -j3 && python3 tests/full.py && python3 tests/integration.py && python3 tests/parity.py && python3 tests/recovery.py && python3 tests/lifecycle.py && python3 tests/operations.py && make -f tests/Makefile richtext vectors json-encoding'
