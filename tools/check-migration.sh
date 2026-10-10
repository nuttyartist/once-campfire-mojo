#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
workspace=${CAMPFIRE_WORKSPACE:-$(dirname "$repo")}
image=${APPLICATION_IMAGE:-campfire-mojo:ci}
name="campfire-migration-gate-$$"
volume="$name-data"
cleanup() { status=$?; if [[ $status != 0 ]]; then docker logs "$name" >&2 || true; fi; docker rm -fv "$name" >/dev/null 2>&1 || true; docker volume rm "$volume" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker volume create "$volume" >/dev/null
docker run --rm --user 0 -v "$workspace:/workspace:ro" -v "$repo:/workspace/once-campfire-mojo:ro" \
  -v "$volume:/migration" -w /workspace/once-campfire-mojo \
  "${TOOLCHAIN_IMAGE:-campfire-local-tools:verified}" python3 tests/import_fixture.py
for site in site restored; do
 port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
 docker run -d --name "$name" -p "127.0.0.1:$port:8080" -v "$volume:/data" \
   -e "CAMPFIRE_DATA=/data/$site" -e "DATABASE_PATH=/data/$site/production.sqlite3" \
   -e "STORAGE_PATH=/data/$site/files" -e "PUBLIC_ORIGIN=http://localhost:$port" "$image" >/dev/null
 python3 "$repo/tests/migrated_smoke.py" "http://localhost:$port" "$workspace/once-campfire-verification/fixtures/default"
 docker stop "$name" >/dev/null
 docker rm -fv "$name" >/dev/null
 if [[ $site == site ]]; then
  docker run --rm -v "$volume:/data" --entrypoint python3 "$image" /app/tools/manage.py backup --data /data/site --destination /data/backup
  docker run --rm -v "$volume:/data" --entrypoint python3 "$image" /app/tools/manage.py restore --source /data/backup --data /data/restored
  docker run --rm -v "$volume:/data" --entrypoint python3 "$image" /app/tools/manage.py check --data /data/restored
 fi
done
printf '%s\n' 'PASS: packaged Disk migration, stopped backup, verified restore and restart'
