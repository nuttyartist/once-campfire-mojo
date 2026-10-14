#!/usr/bin/env python3
"""The adapter must never silently replace or relax an upstream check."""
import importlib.util
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('upstream_prepare', ROOT / 'tools/upstream/prepare.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)
SOURCE = Path(sys.argv.pop(1))


class UpstreamIntegrityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.checkout = Path(cls.directory.name) / 'verification'
        prepare.prepare(SOURCE, cls.checkout)

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def test_upstream_content_is_unchanged(self):
        result = prepare.verify(self.checkout)
        self.assertGreater(result['unchanged_upstream_files'], 20)

    def test_changed_oracles_runner_or_adapter_are_rejected(self):
        for relative in ['bench/contracts.rb', 'browser/smoke.mjs', 'loadgen/src/validation.rs',
                         'bench/validate_acks.rb', 'bench/compare.rb', 'bench/mojo.rb']:
            with self.subTest(path=relative):
                path = self.checkout / relative
                original = path.read_bytes()
                try:
                    path.write_bytes(original + b'\n# an unreviewed change\n')
                    with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                        prepare.verify(self.checkout)
                finally:
                    path.write_bytes(original)


if __name__ == '__main__':
    unittest.main(verbosity=2)
