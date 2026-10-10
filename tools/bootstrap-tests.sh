#!/usr/bin/env bash
# Run on the Docker host. Creates only missing dependencies and disposable seeds.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
workspace=${CAMPFIRE_WORKSPACE:-$(dirname "$repo")}
source "$repo/tools/test-pins.env"
mkdir -p "$workspace"
checkout() {
    local name=$1 revision=$2
    local path="$workspace/$name"
    if [[ ! -d "$path" ]]; then
        git clone --no-checkout "https://github.com/basecamp/$name.git" "$path"
        git -C "$path" checkout --detach "$revision"
    fi
    [[ $(git -C "$path" rev-parse HEAD) == "$revision" ]] || {
        echo "Expected $name at $revision; refusing to reset an existing checkout." >&2
        exit 1
    }
}
checkout once-campfire-verification "$VERIFICATION_REVISION"
checkout once-campfire "$RAILS_REVISION"
verification="$workspace/once-campfire-verification"
if [[ ! -d "$verification/fixtures/default" ]]; then
    seed_args=()
    if [[ -n ${SEED_REFERENCE_IMAGE:-} ]]; then seed_args+=(--image "$SEED_REFERENCE_IMAGE"); fi
    # Verify the Linux-produced WAL database with Linux SQLite too. The host's
    # Apple SQLite can reject WAL sidecars created inside Docker Desktop.
    seed_tools=$(mktemp -d)
    trap 'rm -rf "$seed_tools"' EXIT
    cat > "$seed_tools/sqlite3" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
exec docker run --rm -v "$CAMPFIRE_SEED_WORKSPACE:$CAMPFIRE_SEED_WORKSPACE" \
    "${TOOLCHAIN_IMAGE:-campfire-local-tools:verified}" sqlite3 "$@"
SH
    chmod +x "$seed_tools/sqlite3"
    CAMPFIRE_SEED_WORKSPACE="$workspace" PATH="$seed_tools:$PATH" "$verification/bin/seed" "${seed_args[@]}"
    rm -rf "$seed_tools"
    trap - EXIT
fi
python3 - "$verification" "$SEED_RAILS_REVISION" <<'PY'
import json,sys
from pathlib import Path
seed=Path(sys.argv[1])/'fixtures/default'
assert json.loads((seed/'source.json').read_text())['revision']==sys.argv[2], 'Unexpected seed source revision'
for path in ['db/production.sqlite3','labels.json','reference.env']:
    assert (seed/path).is_file(), 'Incomplete seed: '+path
PY
docker run --rm --init -v "$workspace:/workspace" \
    -w /workspace/once-campfire-verification "${TOOLCHAIN_IMAGE:-campfire-local-tools:verified}" \
    bash -euc 'cargo build --release --locked --manifest-path loadgen/Cargo.toml && bin/check'
printf '%s\n' 'Test dependencies and Rails-generated seed are ready.'
