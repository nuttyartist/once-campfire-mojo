#!/usr/bin/env python3
"""Regressions for asset provenance and side-effect-free build identity."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "tools" / f"{name}.py")
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.assets = module("assets")
        self.assets.ROOT = self.root
        for name in ("assets", "public"):
            shutil.copytree(ROOT / name, self.root / name)

    def check_assets(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.assets.check()

    def test_valid_assets(self):
        self.check_assets()

    def test_stale_manifest_rejected(self):
        (self.root / "public/assets/.manifest.json").write_text("{}")
        with self.assertRaisesRegex(AssertionError, "manifests disagree"):
            self.check_assets()

    def test_missing_file_rejected(self):
        (self.root / "public/service-worker.js").unlink()
        with self.assertRaisesRegex(AssertionError, "missing public files"):
            self.check_assets()

    def test_changed_bytes_rejected(self):
        (self.root / "public/service-worker.js").write_bytes(b"changed")
        with self.assertRaises(AssertionError):
            self.check_assets()

    def test_changed_override_rejected_before_writing(self):
        lock = json.loads((self.root / "assets/source-lock.json").read_text())
        entry = next(item for item in lock["files"] if "local" in item["source"])
        # Restrict this fixture to a local override: no external checkout is needed.
        lock["files"] = [entry]
        (self.root / "assets/source-lock.json").write_text(json.dumps(lock))
        output = self.root / entry["output"]
        before = output.read_bytes()
        (self.root / entry["source"]["local"]).write_bytes(b"changed")
        with self.assertRaisesRegex(ValueError, "hash mismatch"):
            self.assets.vendor(self.root)
        self.assertEqual(output.read_bytes(), before)

    def test_asset_path_cannot_escape(self):
        with self.assertRaisesRegex(ValueError, "Unsafe asset path"):
            self.assets.checked_path(self.root, "../escape")
        (self.root / "escape").symlink_to(self.root.parent)
        with self.assertRaisesRegex(ValueError, "Unsafe asset path"):
            self.assets.checked_path(self.root, "escape/file")

    def test_invalid_build_identity_rejected(self):
        info = module("build_info")
        info.ROOT = self.root
        (self.root / "VERSION").write_text("0.1.0-dev\n")
        with patch.dict(os.environ, {"GIT_REVISION": 'bad"\ncode'}):
            with self.assertRaises(ValueError):
                info.identity()
        with patch.dict(os.environ, {"GIT_REVISION": "a" * 40}):
            self.assertEqual(info.identity(), {"version": "0.1.0-dev", "revision": "a" * 40})
            (self.root / "VERSION").write_text('bad"version')
            with self.assertRaises(ValueError):
                info.identity()

    def test_cli_identity_does_not_initialize_data(self):
        binary = ROOT / "build/campfire"
        self.assertTrue(binary.is_file(), "Run make before the publication regressions")
        data = self.root / "must-not-exist"
        env = dict(os.environ, DATABASE_PATH=str(data / "db"), STORAGE_PATH=str(data / "files"), SECRET_KEY_BASE="", VAPID_PUBLIC_KEY="", VAPID_PRIVATE_KEY="")
        for argument in ("--version", "--help", "-h", "--unknown"):
            result = subprocess.run([str(binary), argument], cwd=self.root, env=env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode == 0, argument != "--unknown", result.stderr)
            if argument == "--version":
                self.assertIn((ROOT / "VERSION").read_text().strip(), result.stdout)
            self.assertFalse(data.exists(), argument)


if __name__ == "__main__":
    unittest.main(verbosity=2)
