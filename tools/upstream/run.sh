#!/usr/bin/env bash
# Linux side of the host gate. The host and this container use identical paths.
set -euo pipefail
repo=$1
verification=$2
workspace=$3
seed=$4
image=$5
output=$6
cd "$verification"
git config --global --add safe.directory "$workspace/once-campfire-mojo"
git config --global --add safe.directory "$verification"
cargo build --release --locked --manifest-path loadgen/Cargo.toml
bin/check
ruby "$repo/tests/upstream_adapter.rb" "$verification"
read -r server_cpus client_cpus port < <(python3 - <<'PY'
import os
import socket
cpus = sorted(os.sched_getaffinity(0))
if len(cpus) < 2:
    raise SystemExit('Upstream verification needs at least two available CPUs')
split = min(4, len(cpus)//2)
with socket.socket() as listener:
    listener.bind(('127.0.0.1', 0))
    print(','.join(map(str,cpus[:split])), ','.join(map(str,cpus[split:split+4])), listener.getsockname()[1])
PY
)
export MOJO_IMAGE="$image"
common=(--apps mojo --port "$port" --workspace "$workspace" --seed "$seed" --env-file "$seed/reference.env"
    --rounds 2 --duration 2 --concurrencies 16 --cpus "$server_cpus" --client-cpus "$client_cpus")
bin/benchmark "${common[@]}" --output "$output/routes"
bin/benchmark "${common[@]}" --mixed-write-rate 10 --output "$output/mixed"
# The host writes its own after-run report under a different user ID on Linux.
python3 "$repo/tools/upstream/prepare.py" --checkout "$verification" --output "$output/upstream-integrity-runner.json"
