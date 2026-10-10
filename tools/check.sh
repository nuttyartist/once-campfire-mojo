#!/usr/bin/env bash
# Runs inside the pinned Linux toolchain image after tools/bootstrap-tests.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
bash tools/format.sh
python3 tools/check_publication.py --rails ../once-campfire
make -j"${BUILD_JOBS:-3}"
python3 tests/publication.py
python3 tests/source_safety.py
python3 -m compileall -q tools tests bench
for suite in posting_optimizations byte_http replacement sessions network_failures mixed_workloads storage_recovery full integration recovery lifecycle operations streaming_uploads; do
    python3 "tests/$suite.py"
done
make -f tests/Makefile richtext vectors json-encoding byte-safety job-leases
bash tests/native-safety.sh
printf '%s\n' 'PASS: standalone Mojo correctness gate'
