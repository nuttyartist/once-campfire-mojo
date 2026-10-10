#!/usr/bin/env python3
"""Check the source package's documentation, attribution and generated assets."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import unquote

import assets
import build_info

ROOT = Path(__file__).resolve().parents[1]


def check(rails=None):
    assets.check()
    build_info.identity()
    fixtures = json.loads((ROOT / "tests/corpus/public-fixture-hashes.json").read_text())
    for name, expected_hash in fixtures["sha256"].items():
        assert hashlib.sha256((ROOT / "tests/corpus" / name).read_bytes()).hexdigest() == expected_hash, f"Review public-fixture scanner exception before changing {name}"
    notices = json.loads((ROOT / "licenses/manifest.json").read_text())["notices"]
    expected = {item["path"] for item in notices}
    actual = {str(p.relative_to(ROOT)) for p in (ROOT / "licenses").rglob("*") if p.is_file()}
    assert len(expected) == len(notices), "Duplicate license inventory entry"
    assert actual == expected | {"licenses/manifest.json"}, "License inventory differs from files"
    for item in notices:
        body = assets.checked_path(ROOT, item["path"]).read_bytes()
        assert hashlib.sha256(body).hexdigest() == item["sha256"], item["path"]
        assert item["source"] and item["component"] and item["version"], item

    docs = list(ROOT.glob("*.md")) + list((ROOT / "docs").glob("*.md")) + list((ROOT / "bench").rglob("*.md"))
    for path in docs:
        for target in re.findall(r"\[[^\]]*\]\(([^)]+)\)", path.read_text()):
            if target.startswith(("https://", "http://", "mailto:", "#")):
                continue
            target = unquote(target.split("#", 1)[0].strip("<>"))
            assert target and (path.parent / target).exists(), f"Broken link in {path.relative_to(ROOT)}: {target}"
    for path in (ROOT / "bench/acceptance").glob("*.json"):
        body = path.read_text()
        json.loads(body)
        assert "/Users/" not in body and not re.search(r"/home/[^/]+/", body), f"Personal path in {path}"

    # Rebuild in isolation so a failed check never changes the working tree.
    import shutil
    with tempfile.TemporaryDirectory() as directory:
        copy = Path(directory)
        for name in ("tools", "templates", "assets"):
            shutil.copytree(ROOT / name, copy / name, ignore=shutil.ignore_patterns("__pycache__"))
        (copy / "src").mkdir()
        subprocess.run([sys.executable, str(copy / "tools/compile_templates.py")], check=True)
        assert (copy / "src/templates.mojo").read_bytes() == (ROOT / "src/templates.mojo").read_bytes(), "Regenerate src/templates.mojo"
        if rails is not None:
            subprocess.run([sys.executable, str(copy / "tools/update_schema_contract.py"), str(rails.resolve())], check=True)
            for name in ("tools/schema_contract.json", "src/schema_contract.mojo"):
                assert (copy / name).read_bytes() == (ROOT / name).read_bytes(), f"Regenerate {name} from the pinned original"
    print(f"PASS: {len(notices)} notices, {len(docs)} linked documents, portable evidence and generated templates")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rails", type=Path, help="Also regenerate the schema contract from this original checkout")
    check(parser.parse_args().rails)
