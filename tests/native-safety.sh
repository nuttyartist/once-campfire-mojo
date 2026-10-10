#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/sanitizers/corpus
# Seeds are regression HTML and binary/URL boundaries, not generated app output.
python3 - <<'PY'
from pathlib import Path
import json
out=Path('build/sanitizers/corpus')
for i,case in enumerate(json.loads(Path('tests/corpus/expected.json').read_text())['cases']):
    (out/str(i)).write_text(case['body'])
for i,value in enumerate([b'\xff\xc0\x80',b'http://[::1]/',b'https://user:password@example.test/a',b'A===',bytes(range(256))]):
    (out/('binary-'+str(i))).write_bytes(value)
PY
clang -O1 -g -fno-omit-frame-pointer -fsanitize=fuzzer,address,undefined \
  -Ivendor/gumbo/src $(pkg-config --cflags libxml-2.0 glib-2.0) \
  tests/native_fuzz.c native/platform.c native/transport.c vendor/gumbo/src/*.c \
  -o build/sanitizers/native-fuzz $(pkg-config --libs libxml-2.0 glib-2.0 libcurl) \
  -lsqlite3 -lcrypto -lcrypt -lz -lpthread
ASAN_OPTIONS=detect_leaks=1 UBSAN_OPTIONS=halt_on_error=1 \
  build/sanitizers/native-fuzz -seed=20261010 -runs="${FUZZ_RUNS:-10000}" \
  -max_len=32768 -timeout=10 -artifact_prefix=build/sanitizers/ build/sanitizers/corpus \
  > build/sanitizers/fuzz.log 2>&1
printf '%s\n' 'PASS: 10,000 seeded native ABI fuzz executions under ASan/UBSan (see build/sanitizers/fuzz.log)'
