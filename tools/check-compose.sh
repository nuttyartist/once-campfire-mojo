#!/usr/bin/env bash
# Exercise the documented named-volume backup flow using a unique test project.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
image=${APPLICATION_IMAGE:-campfire-mojo:ci}
work=$(mktemp -d)
export COMPOSE_PROJECT_NAME="campfire-docs-gate-$$"
export COMPOSE_FILE="$repo/compose.yaml:$work/override.yaml"
export CAMPFIRE_TEST_IMAGE="$image"
export CAMPFIRE_TEST_PORT
CAMPFIRE_TEST_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
cat > "$work/override.yaml" <<'YAML'
services:
  campfire:
    image: ${CAMPFIRE_TEST_IMAGE}
    environment:
      PUBLIC_ORIGIN: http://localhost:${CAMPFIRE_TEST_PORT}
    ports: !override
      - "127.0.0.1:${CAMPFIRE_TEST_PORT}:8080"
YAML
cleanup() {
  status=$?
  if [[ $status != 0 ]]; then docker compose logs --tail 100 >&2 || true; fi
  docker compose down --volumes >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
docker compose up -d --no-build --pull never
port=$(docker compose port campfire 8080 | sed 's/.*://')
for _ in $(seq 1 120); do
  if curl -fsS "http://localhost:$port/up" >/dev/null 2>&1; then break; fi
  sleep .25
done
curl -fsS "http://localhost:$port/up" >/dev/null
docker compose stop campfire
bash tools/admin.sh backup --data /data --destination /data/backups/before-upgrade
docker compose run --rm --no-deps --entrypoint tar campfire \
  -czf - -C /data/backups before-upgrade > "$work/backup.tar.gz"
mkdir -m 700 "$work/input" "$work/restore"
tar -xzf "$work/backup.tar.gz" -C "$work/input"
docker run --rm --network none --user 0 --entrypoint python3 \
  -v "$work/input:/backup:ro" -v "$work/restore:/restore" "$image" \
  /app/tools/manage.py restore --source /backup/before-upgrade --data /restore/site
docker run --rm --network none --user 0 --entrypoint python3 \
  -v "$work/restore:/restore" "$image" /app/tools/manage.py check --data /restore/site
docker compose up -d --no-build --pull never
for _ in $(seq 1 120); do
  if curl -fsS "http://localhost:$port/up" >/dev/null 2>&1; then break; fi
  sleep .25
done
curl -fsS "http://localhost:$port/up" >/dev/null
printf '%s\n' 'PASS: documented Compose named-volume stop, backup, archive, verified restore and restart'
