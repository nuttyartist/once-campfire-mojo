# Development

Use the pinned Linux toolchain with Mojo 1.1.0. Host prerequisites for the complete
test bootstrap are Docker, Git, Ruby, Python 3.11 or newer, Node.js 22.18 or newer (CI uses 24) and npm. Application
compilers/native dependencies live in the toolchain image. The HTTP app builds
without a Rust or C Campfire checkout.

```sh
docker build -f bench/Dockerfile.tools -t campfire-local-tools:verified .
bash tools/bootstrap-tests.sh
workspace=$(cd .. && pwd)
docker run --rm --init -e CAMPFIRE_TEST_NO_AFFINITY=1 \
  -v "$workspace:/workspace" -w /workspace/once-campfire-mojo \
  campfire-local-tools:verified bash tools/check.sh
bash tools/build-image.sh campfire-mojo:ci
bash tools/check-migration.sh
bash tools/check-browser.sh
bash tools/check-upstream.sh
bash tools/check-package.sh
bash tools/check-compose.sh
bash tools/check-security.sh
```

Use the checkout name `once-campfire-mojo` for these mount examples. Bootstrap
creates only missing sibling Rails/verification checkouts at immutable pins;
it refuses to reset a checkout with a different revision. Generated credentials
and fixture databases stay outside this repository. No reference server runs in
the deployed image. The separate [three-port benchmark](../bench/README.md) also
needs the Rust/C checkouts and documented patches.

The main check runs publication/asset/license consistency, the source-safety
guard, CLI regressions, application/fault/recovery tests, independent Rails and
crypto vectors, and native adapter ASan/UBSan fuzzing. Browser/package gates use
disposable containers and volumes. They never use your real Campfire volume.
The [independent upstream gate](upstream-verification.md) runs the pinned shared
browser, frontend and HTTP checks directly, with exact durable-job accounting.
Tests fail when prerequisites are missing; do not replace failures with skips.

## Editing and formatting

Inside the toolchain container:

```sh
bash tools/format.sh --write
make -j3
bash tools/format.sh
python3 tests/publication.py
```

The formatter is the `mblack` shipped with the pinned Mojo distribution. Its
check includes handwritten application and test Mojo files; generated templates
and the generated schema contract have separate reproduction checks. No format
tool is run over vendored third-party code. `build/generated/build_info.mojo` is
derived from `VERSION` and the selected Git revision and is not committed.

Use [the module map](architecture.md) to find code. Application/native ownership
changes must respect [SAFETY.md](../SAFETY.md). See [frontend updates](frontend.md)
for the vendoring and template workflow. Recreate rich-text golden data only
with the pinned original Rails image via `tools/regenerate-corpus.sh`.

The GitHub workflow uses native Linux ARM64/amd64 runners, read-only permissions,
pinned actions and retained validation logs. It is prepared locally but has not
been run remotely. Local amd64 emulation is recorded separately from native
platform evidence. A private security contact and native amd64 host validation
are currently deferred; [SECURITY.md](../SECURITY.md) records that status.
