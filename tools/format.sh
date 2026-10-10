#!/usr/bin/env bash
# Use the formatter installed alongside the pinned Mojo compiler.
set -euo pipefail
cd "$(dirname "$0")/.."
args=(--check)
if [[ ${1:-} == --write ]]; then args=(); elif [[ $# != 0 ]]; then echo 'usage: tools/format.sh [--write]' >&2; exit 2; fi
files=()
for file in src/*.mojo tests/*.mojo; do
  case "$file" in src/templates.mojo|src/schema_contract.mojo) continue ;; esac
  files+=("$file")
done
mblack --target-version mojo --workers 1 "${args[@]}" "${files[@]}"
