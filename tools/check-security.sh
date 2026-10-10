#!/usr/bin/env bash
# All source/image analysis runs locally. Only public advisory databases are fetched.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
source "$repo/tools/security-pins.env"
python3 "$repo/tools/check_publication.py"
python3 - "$repo" <<'PY'
import hashlib, json, subprocess, sys
from pathlib import Path
root = Path(sys.argv[1])
pins = json.loads((root / 'tests/corpus/public-fixture-hashes.json').read_text())['sha256']
for name, expected in pins.items():
    records = subprocess.check_output(['git', '-C', str(root), 'rev-list', '--objects', '--all', '--', f'tests/corpus/{name}'], text=True)
    for record in records.splitlines():
        object_id, _, path = record.partition(' ')
        if path == f'tests/corpus/{name}':
            body = subprocess.check_output(['git', '-C', str(root), 'cat-file', 'blob', object_id])
            assert hashlib.sha256(body).hexdigest() == expected, f'Review historical fixture scanner exception: {object_id}'
PY
image=${APPLICATION_IMAGE:-campfire-mojo:ci}
report=${SECURITY_REPORT_DIR:-$repo/build/security}
mkdir -p "$report"
report=$(cd "$report" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/source"
# Scan the publication candidate, including untracked non-ignored edits, but not
# local databases, build outputs, reports or ignored fixture secrets.
python3 - "$repo" "$work/source" <<'PY'
from pathlib import Path
import shutil, subprocess, sys
root, target = map(Path, sys.argv[1:])
names = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z', '--cached', '--others', '--exclude-standard']).split(b'\0')
for name in set(names) - {b''}:
    relative = Path(name.decode())
    source = root / relative
    if not source.exists():
        continue
    if source.is_symlink() or not source.resolve().is_relative_to(root.resolve()):
        raise ValueError(f'Unsafe publication path: {relative}')
    destination = target / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
PY
status=0
docker run --rm --network none -v "$repo:/repo:ro" -v "$report:/reports" \
  -e GIT_CONFIG_COUNT=1 -e GIT_CONFIG_KEY_0=safe.directory -e GIT_CONFIG_VALUE_0=/repo \
  "$GITLEAKS_IMAGE" git /repo --log-opts='--all --full-history' --redact \
  --config /repo/.gitleaks.toml --report-format json --report-path /reports/history.json || status=1
docker run --rm --network none -v "$work/source:/source:ro" -v "$report:/reports" \
  "$GITLEAKS_IMAGE" dir /source --redact --config /source/.gitleaks.toml \
  --report-format json --report-path /reports/source.json || status=1
docker save -o "$work/image.tar" "$image"
docker run --rm -v "$work/image.tar:/image.tar:ro" -v "$report:/reports" \
  -v campfire-trivy-cache:/root/.cache/trivy "$TRIVY_IMAGE" image --input /image.tar \
  --scanners vuln --format json --output /reports/image.json --exit-code 1 \
  --severity HIGH,CRITICAL || status=1
# Vendored frontend components cannot reliably be identified from minified JS.
docker run --rm -v "$repo/assets/components.cdx.json:/components.json:ro" -v "$report:/reports" \
  -v campfire-trivy-cache:/root/.cache/trivy "$TRIVY_IMAGE" sbom /components.json \
  --format json --output /reports/frontend.json --exit-code 1 --severity HIGH,CRITICAL || status=1
docker image inspect "$image" > "$report/image-metadata.json"
if [[ $status != 0 ]]; then
  printf '%s\n' "FAIL: inspect local redacted reports in $report" >&2
  exit "$status"
fi
printf '%s\n' "PASS: history/source secret checks and HIGH/CRITICAL image/frontend advisories; reports: $report"
