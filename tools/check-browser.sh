#!/usr/bin/env bash
# Host gate against the production image; all data is disposable and removed.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
image=${APPLICATION_IMAGE:-campfire-mojo:ci}
name="campfire-mojo-gate-$$"
work=$(mktemp -d)
cleanup() { status=$?; if [[ $status != 0 ]]; then docker logs "$name" >&2 || true; fi; docker rm -fv "$name" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
if [[ -z ${PLAYWRIGHT_MODULE:-} ]]; then
    npm install --prefix "$work/node" --no-audit --no-fund --ignore-scripts playwright@1.63.0
    export PLAYWRIGHT_MODULE="$work/node/node_modules/playwright/index.mjs"
    "$work/node/node_modules/.bin/playwright" install --with-deps chromium
fi
port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
docker run -d --name "$name" -p "127.0.0.1:$port:8080" -e PUBLIC_ORIGIN="http://localhost:$port" "$image" >/dev/null
node "$repo/tests/browser_smoke.mjs" --base "http://localhost:$port"
docker stop "$name" >/dev/null
docker start "$name" >/dev/null
for _ in $(seq 1 120); do
    if curl -fsS "http://localhost:$port/up" >/dev/null 2>&1; then break; fi
    sleep .25
done
curl -fsS "http://localhost:$port/up" >/dev/null
docker rm -fv "$name" >/dev/null
cat > "$work/Caddyfile" <<'CADDY'
{
    auto_https disable_redirects
}
https://localhost:8443 {
    tls internal
    reverse_proxy 127.0.0.1:3000
}
CADDY
docker run -d --name "$name" -p 127.0.0.1::8443 \
    -v "$work/Caddyfile:/app/deploy/Caddyfile:ro" "$image" >/dev/null
port=$(docker port "$name" 8443/tcp | sed 's/.*://')
# Origin must be explicit, including the host's mapped port.
docker rm -fv "$name" >/dev/null
docker run -d --name "$name" -p "127.0.0.1:$port:8443" \
    -e PUBLIC_ORIGIN="https://localhost:$port" \
    -v "$work/Caddyfile:/app/deploy/Caddyfile:ro" "$image" >/dev/null
for _ in $(seq 1 120); do
    if docker exec "$name" cat /data/caddy/caddy/pki/authorities/local/root.crt > "$work/ca.crt" 2>/dev/null && curl -fsS --cacert "$work/ca.crt" "https://localhost:$port/up" >/dev/null 2>&1; then break; fi
    sleep .25
done
python3 "$repo/tests/deployment_tls.py" "$port" "$work/ca.crt"
printf '%s\n' 'PASS: production browser, process restart and TLS deployment gates'
