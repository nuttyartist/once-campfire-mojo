#!/usr/bin/env python3
"""Independent standard-library checks of the Mojo binary wire fixture."""
import base64, gzip, hashlib, subprocess
from pathlib import Path
root = Path(__file__).resolve().parents[1]
output = subprocess.check_output([root / 'build/byte-safety'], cwd=root, text=True)
records = {name: base64.b64decode(value, validate=True) for name, value in
           (line.split(' ', 1) for line in output.splitlines() if not line.startswith('PASS:'))}
raw = bytes(range(256))
assert records['binary'] == raw
assert records['digest'] == hashlib.sha256(raw).digest()
assert records['frame'] == b'\x81\x7e\x01\x00' + raw
head, body = records['gzip'].split(b'\r\n\r\n', 1)
assert b'Content-Encoding: gzip' in head
assert f'Content-Length: {len(body)}'.encode() in head
assert gzip.decompress(body) == raw
assert records['marshal_min'] == b'\x04\x08l-\x09' + (1 << 63).to_bytes(8, 'little')
text = 'שלום 🔥'.encode()
assert records['marshal_utf8'] == b'\x04\x08I"' + bytes([len(text)+5]) + text + b'\x06:\x06ET'
print(output.splitlines()[-1])
print('PASS: 6 independent binary wire encodings (Python standard library)')
