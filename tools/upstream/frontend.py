#!/usr/bin/env python3
"""Run upstream controller regressions against the exact assets served by Mojo."""
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
manifest = json.loads((ROOT / 'assets/manifest.json').read_text())
for test, asset in [('sidebar-reload', 'controllers/rooms_list_controller.js'),
                    ('editor-preservation', 'controllers/rooms_list_controller.js'),
                    ('autocomplete-json', 'lib/autocomplete/base_autocomplete_handler.js')]:
    source = ROOT / 'public/assets' / manifest[asset]['digested_path']
    subprocess.run(['node', str(Path(sys.argv[1]) / 'test' / (test + '.mjs')), str(source)], check=True)
