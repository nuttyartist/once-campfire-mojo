# Campfire in Mojo

A standalone Mojo 1.1 port of [Basecamp Campfire](https://github.com/basecamp/once-campfire), targeting the stock local Disk installation at Rails `b52b244`. Routing, authentication, permissions, SQL, rendering, Action Cable, storage policy and durable jobs are Mojo. Small C adapters expose POSIX and established native libraries; the server does not run Python, Ruby, or either reference Campfire implementation.

The ten findings from the local replacement audit have regression tests and fixes. The port also includes recoverable file cleanup, schema-checked Disk import, Rails encrypted session migration, large streamed uploads, Linux ARM64/amd64 images, browser/TLS tests and CI. [PORT_STATUS.md](PORT_STATUS.md) states the supported contract and intentional differences. This repository is prepared for upstream review; it has not been uploaded or released.

Binary data uses owned byte buffers with explicit UTF-8 decoding. FFI and raw-pointer operations are confined to one checked native boundary; see [SAFETY.md](SAFETY.md) for ownership rules and regression coverage.

## Local comparison — 2026-10-10

<!-- BENCHMARK_BEGIN -->
| Workload (completed requests/sec) | Rust* | C* | Mojo |
|---|---:|---:|---:|
| Room page | 60,644 | 70,577 | 60,668 |
| Messages page | 51,635 | 65,858 | 60,781 |
| Sidebar | 60,455 | 66,963 | 76,689 |
| Search | 58,033 | 66,958 | 71,122 |
| Post a message | 1,259 | 422 | 865 |
| Backend KLOC | 30.9 | 94.8 | 8.0 |

**277,605 messages and 832,815 recipient completions audited across all timed runs and warmups. No missing messages, FTS rows or receipts; no pending, failed or dropped jobs.** Posting rounds (completed messages/sec): Rust: 1,189, 1,344, 1,259; C: 342, 429, 422; Mojo: 878, 853, 865. Raw results: `bench/results/2026-10-10-m4-byte-safety-lock-budget/`.

Measured commits: Rust `aea2e0768426`, C `f5db6695873b`, Mojo `c62f43845715`. Audited Mojo application source is `cf7be91`; later commits change comparison tooling, tests or documentation only.
<!-- BENCHMARK_END -->

The tracked [comparison summary](bench/acceptance/2026-10-10-byte-safety.json) records all rounds, binary hashes and completion audits. Raw acknowledgement files are kept locally and excluded from Git. An earlier attempt stopped on a C HTTP 503 caused by writer contention under its shorter lock budget. The controlled regression reproduced the failure; after aligning the opt-in reference budgets with Mojo, all nine runs were repeated. The aborted attempt remains in `bench/results/2026-10-10-m4-byte-safety/` and is not mixed into the table.

These are **local durability-patched Rust and C builds**, not stock upstream performance claims. Every application uses SQLite WAL `synchronous=FULL`, atomic message/outbox admission, persisted retry state, recipient receipts and a 10-second SQLite write-lock budget. Posting throughput includes the final queue drain. The harness requires every acknowledged message, exact body, FTS entry and expected recipient receipt, and rejects failed, pending or dropped work.

The timed workloads prepare three push recipients per message and exercise the same endpoint-policy rejection. They do not time external push encryption/network delivery, and have no connected Cable subscribers. Actual encryption, provider acceptance/retry and live browser fanout have separate correctness tests. External side effects are at-least-once; a crash after remote acceptance but before the local receipt can cause a duplicate.

Method: Apple M4, 24 GiB RAM; native ARM64 Linux in Docker Desktop; three rounds in rotating Rust/C/Mojo order; 2-second warmups, 8-second samples, 16 keep-alive HTTP/1.1 clients accepting gzip. Servers and their job workers share VM CPUs `0-3`; load generation uses `4-7`. Each application has a 64 MiB response-cache budget. Each retains its own scheduler, cache implementation and compression strategy. This compares completed workloads under a stated configuration, not intrinsic language speed. amd64 emulation is excluded from timing.

The performance runner first checks nine live DOM/SQL/cookie/delivery scenarios. It verifies record-derived Mojo DOM IDs before adapting that known current-Rails security change for comparison with older Rust/C markup. One original C sidebar-initials difference remains explicit. [Reference patches](bench/reference-patches/README.md) record exact bases and the unchanged reference media-golden test limitation.

## Build and run

From this checkout, on a Docker host:

```sh
docker build -f bench/Dockerfile.tools -t campfire-local-tools:verified .
docker compose build
docker compose up -d
```

Open `http://localhost:8080`. The first visit creates the account and administrator. [DEPLOYMENT.md](DEPLOYMENT.md) covers persistent data, TLS, importing a stopped Rails installation, backup/restore and recovery.

## Test from a clean checkout

Docker, Git, Ruby, Python 3, Node.js and npm are needed on the host. Application dependencies and compilers live in the toolchain image. Bootstrap fetches immutable Rails/verification revisions into sibling directories and generates independent Rails fixtures with fresh disposable credentials. It refuses to reset existing checkouts with a different revision.

```sh
docker build -f bench/Dockerfile.tools -t campfire-local-tools:verified .
bash tools/bootstrap-tests.sh
workspace=$(cd .. && pwd)
docker run --rm --init -e CAMPFIRE_TEST_NO_AFFINITY=1 \
  -v "$workspace:/workspace" -w /workspace/once-campfire-mojo \
  campfire-local-tools:verified bash tools/check.sh
docker build -t campfire-mojo:ci .
bash tools/check-migration.sh
bash tools/check-browser.sh
```

`tools/check.sh` is independent of the Rust and C repositories. It runs application/security tests, network and storage fault injection, crash recovery for every persistent job kind, concurrent chat/media checks, large uploads, independent Rails rich-text/signing/encrypted-cookie vectors, Web Push cryptography and native ASan/UBSan fuzzing. The GitHub workflow runs these gates and packaged migration/browser/TLS tests on native Linux ARM64 and amd64 runners. The workflow is checked locally; no remote CI run has occurred.

## Reproduce the three-port comparison

Place `once-campfire-rust`, `once-campfire-c`, `once-campfire-verification` and this repository alongside each other. Use the pinned revisions and apply the checked-in local durability patches described in `bench/reference-patches/README.md`. Build all applications with `bench/build.sh` in the toolchain container, then run:

```sh
bash bench/run-durable.sh bench/results/local-durable
```

The runner fails closed on parity, invalid responses, write-audit differences, job failures, queue drops and incomplete drain. Do not set `CAMPFIRE_TEST_NO_AFFINITY` for measurements. `tests/durable_comparison.py` and `tests/durable_inflight.py` separately verify paused-worker and active-lease crash recovery across all three builds. Raw data is local and ignored by Git. Historical stock-port posting measurements are superseded because their background-work and durability contracts differed.

## Architecture and license

Caddy terminates TLS and proxies to a supervised Mojo parent, four HTTP/Cable processes and three durable-job processes by default. Each process owns a SQLite connection. HTTP workers use nonblocking socket loops; bounded synchronous media/network operations can occupy an individual worker. Expensive preparation happens before short database write transactions. Message, FTS, unread and outbox changes commit together, and live events are size-checked before commit. File deletions have a durable retry table; offline garbage collection recovers unfinished preparations.

Native adapters wrap SQLite, OpenSSL, curl, Gumbo, libvips, zlib and POSIX operations. SQLite 3.53.4, the Nokogiri-compatible Gumbo parser and QR generator sources/licenses are vendored. Python serves build generation, testing and offline administration only. Frontend assets and templates derive from the MIT-licensed original/Rust references. See [PROVENANCE.md](PROVENANCE.md) and retain `MIT-LICENSE`.
