#!/usr/bin/env python3
"""Apply only the reviewed deployment patch; prove all upstream checks unchanged."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
REVISION = dict(line.split('=', 1) for line in (ROOT / 'tools/test-pins.env').read_text().splitlines() if line and not line.startswith('#'))['VERIFICATION_REVISION']


def git(repo, *args):
    return subprocess.check_output(['git', '-c', f'safe.directory={repo.resolve()}', '-C', str(repo), *args])


def verify(checkout):
    if git(checkout, 'rev-parse', 'HEAD').decode().strip() != REVISION:
        raise ValueError('Unexpected upstream revision')
    inventory = {}
    for raw in git(checkout, 'ls-tree', '-rz', '--name-only', REVISION).split(b'\0'):
        if not raw:
            continue
        name = raw.decode()
        body = (checkout / name).read_bytes()
        if name != 'bench/compare.rb' and body != git(checkout, 'show', f'{REVISION}:{name}'):
            raise ValueError(f'Upstream check/source modified: {name}')
        inventory[name] = hashlib.sha256(body).hexdigest()
    # Reverse-checking the exact patch also rejects any other runner changes.
    subprocess.run(['git', '-C', str(checkout), 'apply', '--reverse', '--check', str(ROOT / 'tools/upstream/runner.patch')], check=True)
    # A temporary pristine copy makes comparison independent of patch context fuzz.
    with tempfile.TemporaryDirectory() as directory:
        expected = Path(directory)
        (expected / 'bench').mkdir()
        (expected / 'bench/compare.rb').write_bytes(git(checkout, 'show', f'{REVISION}:bench/compare.rb'))
        subprocess.run(['git', 'apply', str(ROOT / 'tools/upstream/runner.patch')], cwd=expected, check=True)
        if (expected / 'bench/compare.rb').read_bytes() != (checkout / 'bench/compare.rb').read_bytes():
            raise ValueError('Unreviewed runner changes')
    if (checkout / 'bench/mojo.rb').read_bytes() != (ROOT / 'tools/upstream/mojo.rb').read_bytes():
        raise ValueError('Unreviewed Mojo adapter changes')
    return {'revision': REVISION, 'unchanged_upstream_files': len(inventory) - 1,
            'runner_patch_sha256': hashlib.sha256((ROOT / 'tools/upstream/runner.patch').read_bytes()).hexdigest(),
            'adapter_sha256': hashlib.sha256((checkout / 'bench/mojo.rb').read_bytes()).hexdigest(),
            'sha256': inventory}


def prepare(source, destination):
    if destination.exists():
        raise ValueError('Destination must be new')
    subprocess.run(['git', 'clone', '--no-hardlinks', '--no-checkout', str(source), str(destination)], check=True)
    subprocess.run(['git', '-C', str(destination), 'checkout', '--detach', REVISION], check=True)
    subprocess.run(['git', '-C', str(destination), 'apply', '--check', str(ROOT / 'tools/upstream/runner.patch')], check=True)
    subprocess.run(['git', '-C', str(destination), 'apply', str(ROOT / 'tools/upstream/runner.patch')], check=True)
    shutil.copyfile(ROOT / 'tools/upstream/mojo.rb', destination / 'bench/mojo.rb')
    return verify(destination)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path)
    parser.add_argument('--checkout', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = prepare(args.source, args.checkout) if args.source else verify(args.checkout)
    args.output.write_text(json.dumps(result, indent=2) + '\n')
    print(f"PASS: {result['unchanged_upstream_files']} upstream files unchanged; deployment-only runner patch")
