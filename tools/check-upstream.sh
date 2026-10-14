#!/usr/bin/env bash
# Host gate: unchanged independent tests, minimal deployment adapter, fresh data.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
workspace=${CAMPFIRE_WORKSPACE:-$(dirname "$repo")}
verification="$workspace/once-campfire-verification"
image=${APPLICATION_IMAGE:-campfire-mojo:ci}
toolchain=${TOOLCHAIN_IMAGE:-campfire-local-tools:verified}
node -e 'const [major,minor]=process.versions.node.split(".").map(Number); if (major<22 || (major===22 && minor<18)) throw Error("Node.js >=22.18 required")'
mkdir -p "$repo/build/upstream"
work=$(mktemp -d "$repo/build/upstream/run-XXXXXXXX")
name="campfire-mojo-upstream-browser-$$"
runner="campfire-mojo-upstream-runner-$$"
volume="$runner-data"
cleanup() {
    status=$?
    if docker inspect "$name" >/dev/null 2>&1; then docker logs "$name" > "$work/browser-server.log" 2>&1 || true; fi
    docker rm -fv "$name" >/dev/null 2>&1 || true
    docker rm -fv "$runner" >/dev/null 2>&1 || true
    for owned in $(docker ps -aq --filter "label=campfire.verification.run=$runner"); do
        docker rm -fv "$owned" >/dev/null 2>&1 || true
    done
    docker volume rm "$volume" >/dev/null 2>&1 || true
    echo "Upstream verification evidence: $work (exit $status)"
}
trap cleanup EXIT
python3 "$repo/tools/upstream/prepare.py" --source "$verification" --checkout "$work/verification" --output "$work/upstream-integrity-before.json"
python3 "$repo/tests/upstream_integrity.py" "$verification"
# Use the upstream lockfile and its normal Playwright import, without source edits.
(cd "$work/verification" && npm ci --no-audit --no-fund && npx playwright install --with-deps chromium)
python3 "$repo/tools/upstream/frontend.py" "$work/verification"
docker run -d --name "$name" -p 127.0.0.1::8080 "$image" >/dev/null
port=$(docker port "$name" 8080/tcp | sed 's/.*://')
docker rm -fv "$name" >/dev/null
docker run -d --name "$name" -p "127.0.0.1:$port:8080" -e PUBLIC_ORIGIN="http://localhost:$port" "$image" >/dev/null
for _ in $(seq 1 120); do
    if curl -fsS "http://localhost:$port/up" >/dev/null 2>&1; then break; fi
    sleep .25
done
curl -fsS "http://localhost:$port/up" >/dev/null
failed=0
if ! "$work/verification/bin/browser" --base "http://localhost:$port" 2>&1 | tee "$work/browser.log"; then
    failed=1
fi
if ! docker exec -i "$name" python3 - < "$repo/tools/upstream/browser_jobs.py"; then failed=1; fi
if ! ruby -r "$work/verification/bench/comparison_support" -r "$repo/tools/upstream/mojo" \
    -e 'MojoVerification.stop(*ARGV)' "$name" "$work/browser-server.log"; then failed=1; fi
docker rm -fv "$name" >/dev/null
# Docker socket access is restricted to this local trusted test adapter. No push.
docker build --build-arg "TOOLCHAIN_IMAGE=$toolchain" -f "$repo/tools/upstream/Dockerfile" -t campfire-verification-tools:local "$repo"
docker volume create --label "campfire.verification.run=$runner" "$volume" >/dev/null
if ! docker run --rm --init --name "$runner" --network host -e "MOJO_VERIFICATION_RUN=$runner" \
    -e "MOJO_VERIFICATION_VOLUME=$volume" -e MOJO_VERIFICATION_RUNTIME=/campfire-verification \
    -v "$volume:/campfire-verification" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$workspace:$workspace:ro" -v "$work:$work" \
    campfire-verification-tools:local bash "$repo/tools/upstream/run.sh" \
    "$repo" "$work/verification" "$workspace" "$verification/fixtures/default" "$image" "$work" \
    2>&1 | tee "$work/harness.log"; then
    failed=1
fi
python3 "$repo/tools/upstream/prepare.py" --checkout "$work/verification" --output "$work/upstream-integrity-after.json"
if [[ $failed != 0 ]]; then
    echo 'FAIL: one or more upstream checks failed; inspect the retained browser and harness logs' >&2
    exit 1
fi
printf '%s\n' 'PASS: unchanged upstream browser, frontend, harness tests, all eight routes and mixed writes; FULL durability and exact job receipts'
