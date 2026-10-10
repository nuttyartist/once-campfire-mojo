#!/usr/bin/env bash
# Export an existing, tested local candidate. No remote/tag/push operation exists here.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo"
image=${1:?Usage: release-local.sh IMAGE NEW_OUTPUT_DIRECTORY}
output=${2:?Usage: release-local.sh IMAGE NEW_OUTPUT_DIRECTORY}
[[ -z $(git status --porcelain) ]] || { echo 'A clean committed source tree is required' >&2; exit 1; }
[[ ! -e $output ]] || { echo 'Output must be a new directory' >&2; exit 1; }
revision=$(git rev-parse HEAD)
[[ $(docker image inspect "$image" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}') == "$revision" ]] || { echo 'Image and source revisions differ' >&2; exit 1; }
APPLICATION_IMAGE="$image" bash tools/check-package.sh
mkdir -p "$output"
output=$(cd "$output" && pwd)
git archive --format=tar.gz --prefix=campfire-mojo/ -o "$output/source.tar.gz" HEAD
docker save -o "$output/image.tar" "$image"
docker image inspect "$image" > "$output/image-metadata.json"
docker run --rm --network none --entrypoint dpkg-query "$image" -W > "$output/packages.txt"
cp -R bench/acceptance "$output/acceptance"
cp VERSION CHANGELOG.md THIRD_PARTY_NOTICES.md "$output/"
python3 - "$output" "$revision" <<'PY'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1])
(root / 'candidate.json').write_text(json.dumps({'revision': sys.argv[2], 'version': (root / 'VERSION').read_text().strip(), 'status': 'local candidate; not a published or supported release', 'acceptance': 'Historical measured revisions are recorded inside each acceptance summary; export does not rerun or certify them.'}, indent=2) + '\n')
with (root / 'SHA256SUMS').open('w') as stream:
    for path in sorted(root.rglob('*')):
        if path.is_file() and path.name != 'SHA256SUMS':
            with path.open('rb') as source:
                digest = hashlib.file_digest(source, 'sha256').hexdigest()
            stream.write(f'{digest}  {path.relative_to(root)}\n')
PY
printf '%s\n' "Local candidate exported to $output"
