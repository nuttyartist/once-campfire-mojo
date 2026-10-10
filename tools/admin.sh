#!/usr/bin/env bash
# Run the packaged offline administration tools against the Compose data volume.
# The database lock rejects mutations while a server is using the volume.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
compose=(docker compose)
if [[ -f "$repo/.env" ]]; then compose+=(--env-file "$repo/.env"); fi
exec "${compose[@]}" run --rm --no-deps --entrypoint python3 campfire /app/tools/manage.py "$@"
