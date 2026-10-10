#!/usr/bin/env bash
# Inspect a disposable image instance without starting the application.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
image=${APPLICATION_IMAGE:-campfire-mojo:ci}
version=$(cat "$repo/VERSION")
revision=$(docker image inspect "$image" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')
[[ $revision =~ ^[0-9a-f]{40}$ ]]
[[ $(docker image inspect "$image" --format '{{index .Config.Labels "org.opencontainers.image.version"}}') == "$version" ]]
[[ $(docker run --rm --network none --read-only --tmpfs /data:ro "$image" --version) == "Campfire Mojo $version ($revision)" ]]
docker run --rm -i --network none --read-only --tmpfs /data:ro --entrypoint python3 "$image" - <<'PY'
import hashlib, json, os
from pathlib import Path
assert os.getuid() == 10001
root = Path('/app')
for name in ('MIT-LICENSE', 'THIRD_PARTY_NOTICES.md', 'VERSION', 'build-info.txt'):
    assert (root / name).stat().st_size > 0, name
manifest = json.loads((root / 'licenses/manifest.json').read_text())
for entry in manifest['notices']:
    assert hashlib.sha256((root / entry['path']).read_bytes()).hexdigest() == entry['sha256'], entry['path']
for name in ('libKGENCompilerRTShared.so', 'libMSupportGlobals.so', 'libAsyncRTRuntimeGlobals.so'):
    assert (Path('/usr/local/lib/mojo') / name).is_file(), name
assert Path('/usr/share/common-licenses').is_dir()
assert not list(Path('/data').iterdir()), 'Identity check created application data'
print(f"PASS: non-root package, side-effect-free identity, {len(manifest['notices'])} verified notices and runtime dependencies")
PY
