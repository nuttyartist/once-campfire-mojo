#!/usr/bin/env bash
# Build a local image with revision/version labels. Never pushes an image.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
version=$(cat VERSION)
revision=$(git rev-parse HEAD)
image=${1:-campfire-mojo:local}
shift || true
exec docker build --build-arg "GIT_REVISION=$revision" --build-arg "APP_VERSION=$version" \
  --build-arg "SOURCE_URL=${SOURCE_URL:-local}" --build-arg "TOOLCHAIN_IMAGE=${TOOLCHAIN_IMAGE:-campfire-local-tools:verified}" \
  -t "$image" "$@" "$repo"
