#!/usr/bin/env python3
"""Verify or restore the pinned frontend without executing upstream code."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def checked_path(root, relative):
    path = root / relative
    if path.is_symlink() or not path.resolve().is_relative_to(root.resolve()):
        raise ValueError(f"Unsafe asset path: {relative}")
    return path


def digest(data):
    return hashlib.sha256(data).hexdigest()


def check():
    lock = json.loads((ROOT / "assets/source-lock.json").read_text())
    expected = {entry["output"] for entry in lock["files"]}
    actual = {str(p.relative_to(ROOT)) for p in (ROOT / "public").rglob("*") if p.is_file()}
    assert actual == expected | {"public/assets/.manifest.json"}, "Unrecorded or missing public files"
    for entry in lock["files"]:
        assert digest(checked_path(ROOT, entry["output"]).read_bytes()) == entry["sha256"], entry["output"]
        if "local" in entry["source"]:
            assert digest(checked_path(ROOT, entry["source"]["local"]).read_bytes()) == entry["sha256"], entry["source"]
    manifest = (ROOT / "assets/manifest.json").read_bytes()
    assert (ROOT / "public/assets/.manifest.json").read_bytes() == manifest, "Asset manifests disagree"
    for value in json.loads(manifest).values():
        assert checked_path(ROOT / "public/assets", value["digested_path"]).is_file(), value
    print(f"PASS: {len(expected)} pinned frontend files, overrides and both manifests")


def vendor(sources):
    lock = json.loads((ROOT / "assets/source-lock.json").read_text())
    prepared = []
    for entry in lock["files"]:
        source = entry["source"]
        if "local" in source:
            body = checked_path(ROOT, source["local"]).read_bytes()
        else:
            repo = sources / source["repository"].split("/")[1]
            body = subprocess.check_output(["git", "-c", f"safe.directory={repo.resolve()}", "-C", str(repo), "show", f"{source['revision']}:{source['path']}"])
        if digest(body) != entry["sha256"]:
            raise ValueError(f"Upstream/override hash mismatch: {entry['output']}")
        prepared.append((checked_path(ROOT, entry["output"]), body))
    # Validate every source before replacing any output. No network is implicit.
    for path, body in prepared:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(body)
    (ROOT / "public/assets/.manifest.json").write_bytes((ROOT / "assets/manifest.json").read_bytes())
    check()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["check", "vendor"])
    parser.add_argument("--sources", type=Path, default=ROOT.parent, help="Parent of the pinned source checkouts (vendor only)")
    args = parser.parse_args()
    if args.command == "check":
        check()
    else:
        vendor(args.sources)
