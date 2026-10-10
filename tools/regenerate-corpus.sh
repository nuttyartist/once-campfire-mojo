#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
source "$repo/tools/test-pins.env"
image=${RAILS_REFERENCE_IMAGE:-ghcr.io/basecamp/once-campfire:main}
revision=$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image")
[[ "$revision" == "$RAILS_REVISION" ]] || { echo 'Wrong original Rails revision' >&2; exit 1; }
docker run --rm --entrypoint bash \
    -e RAILS_ENV=production -e SECRET_KEY_BASE=richtext-corpus-disposable-local-key-0000000000000000000000000000000 \
    -e DATABASE_URL=sqlite3:/tmp/corpus.sqlite3 -e RAILS_LOG_LEVEL=error \
    -e RICHTEXT_FUZZ_CASES=200 -e RICHTEXT_MUTATION_CASES=200 \
    -v "$repo/tests/corpus:/corpus" "$image" -euc \
    'bin/rails db:schema:load >/dev/null && bin/rails runner /corpus/generate.rb'
