#!/usr/bin/env bash
# Run inside bench/Dockerfile.tools, with all repositories at /workspace.
set -euo pipefail
root=${CAMPFIRE_WORKSPACE:-/workspace}
cd "$root/once-campfire-c"
for dep in picohttpparser sqlite zlib-ng yyjson openssl libxcrypt gumbo qrcodegen nghttp2 curl; do
    bash "vendor/scripts/$dep.sh"
done
make deps-build
make MODE=bench build-app -j3
cd "$root/once-campfire-rust"
git submodule update --init
cargo build --release --locked -p campfire -j3
cd "$root/once-campfire-verification"
cargo build --release --locked --manifest-path loadgen/Cargo.toml -j3
bin/check
cd "$root/once-campfire-mojo"
make SQLITE_LIB="$root/once-campfire-c/vendor/build/sqlite-clang/libsqlite3.a"
