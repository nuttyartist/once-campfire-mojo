# Campfire in Mojo

A local Mojo 1.1 application port of Basecamp Campfire. Application routing, permissions, SQL, rendering, Action Cable, delivery and storage policy are written in Mojo. Generic C adapters connect POSIX, SQLite, OpenSSL, curl, Gumbo and libvips.

**The previously listed large-upload, amd64 deployment and real-browser push gaps are closed and tested.** See [PORT_STATUS.md](PORT_STATUS.md) for evidence, compatibility differences and deployment limits, and [DEPLOYMENT.md](DEPLOYMENT.md) to run or migrate an installation. Nothing has been published or pushed.

The original five-workload benchmark implementation is preserved in Git commit `41edc39`. Its historical measurements remain under `bench/results/2026-10-09-m4-matched/`. A fresh comparison of the expanded application is recorded below.

## Durable completed-work results — 2026-10-10

| Workload (completed requests/sec) | Rust* | C* | Mojo |
|---|---:|---:|---:|
| Room page | 64,171 | 75,605 | 112,941 |
| Messages page | 61,043 | 78,479 | 126,717 |
| Sidebar | 71,586 | 82,724 | 129,539 |
| Search | 70,398 | 80,086 | 136,136 |
| Post a message | 1,183 | 418 | 892 |
| Backend KLOC | 30.9 | 94.8 | 7.1 |

Median of three rotating-order rounds on this Apple M4. **Rust and C are local durability-patched builds**, not stock upstream results. All three use SQLite WAL `synchronous=FULL`, atomic message/outbox admission and per-recipient receipts. Posting includes final queue-drain time. Every response and acknowledged message/FTS row passed validation; **281,807 accepted messages and 845,421 recipient completions** were audited, including warmups, with no missing work, failed jobs, queue drops or pending jobs.

Posting runs (completed messages/sec): Rust **1,183 / 1,497 / 718**; C **418 / 423 / 413**; Mojo **889 / 892 / 899**. The substantial Rust spread and read-rate variation are retained in the raw results; the medians are not an isolated language-speed ranking. Requests accept gzip, and each port retains its native compression and scheduling behavior. C retains per-kind worker pools; Rust/Mojo share their durable workers. All have three push workers and the same total server CPU allocation.

The timed push endpoints are rejected by the same guard: canonical payloads, recipient selection and badges are prepared, but external network delivery and encryption are outside the timed workloads. Actual Chrome/FCM delivery and independent cryptography pass separate acceptance checks. Cable has no connected subscribers during timing.

Two crash modes pass on all three implementations: 160 posts with workers paused, and 1,200 posts followed by a kill with active leases and already-recorded receipts. Every expected message and subscription receipt survives recovery; a second restart adds no receipts. These are process-crash checks, not physical power-cut tests. External delivery remains at-least-once.

Measured revisions: Rust `ff8fe2e`, C `eb604c5`, Mojo `2e4edc0` (application source `19104f0`). Exact reference patches and their validation limits are in [bench/reference-patches](bench/reference-patches/README.md). Rust formatting/Clippy pass; the seeded Rust and C suites retain the same pinned-FFmpeg video golden-byte mismatch on ARM64, documented there without changing assertions.

Raw rounds, hashes, exact write audits and server logs: `bench/results/2026-10-10-m4-durable-indexed/`. Backend source is 30,925 Rust, 94,787 C and 7,099 Mojo-port lines; the Mojo total includes 6,150 Mojo, 689 generic C adapter and 260 executable template lines. Source counting follows the same documented local convention for every implementation.

## Application coverage

The application now supports first-run setup and invitations, account/profile/admin and room management, text messages and edits, boosts, search, live Action Cable delivery and presence, private-room authorization and revocation, static frontend assets, binary multipart/direct uploads and signed downloads, avatars and logos, verified mentions, sounds, link previews, bot API and webhook replies, and encrypted Web Push transport. The server supervises its workers and persists delivery jobs in SQLite. The status file records the independent tests, reference-version differences and validation scope.

## Benchmark workload and validation

The first version emitted much smaller HTML and used a separate session mechanism.
That version's performance numbers are superseded for comparisons of equal work.

- **Rendering:** the upstream message controls, quick boosts, author avatars, signed URLs,
  timestamps, layouts, styles/importmap tags, sidebar groups/placeholders, search history,
  composer, and notification-help markup. Values come from live SQLite records. Static
  MIT-licensed templates are compiled into Mojo; captured responses are never build inputs.
- **Authentication:** Rails-compatible PBKDF2/HMAC signed `session_token` cookies, the shared
  `sessions` table, 24-character base58 tokens, bcrypt login, activity refresh, revocation,
  active-user and membership checks, and header/origin CSRF checks.
- **Text writes:** canonical rich text, plain-text FTS entry, room timestamp/counter, and
  unread updates for visible, disconnected recipients (the upstream 60-second cutoff).
  The complete Turbo Stream response and room/unread broadcast payloads are prepared.
- **Background work in this benchmark:** workers build room notification payloads,
  select recipients, count badges, and apply the upstream push endpoint guard. All three
  apps receive the same local endpoints, which the upstream guard rejects before network
  delivery or encryption. The durable harness checks exact completion and recipient receipts
  for all three implementations, with no pending, failed or dropped jobs. Local Rust/C
  comparison branches add durable outboxes; all three use SQLite WAL `synchronous=FULL`.
  Posting throughput includes queue-drain time. Historical stock-port posting numbers
  below remain withdrawn as an equal-work comparison.
- **Cache behavior:** bounded responses, data-version invalidation, authorization before
  cache hits, and keys varying by user, URL, gzip, host, browser, Turbo frame and return-room
  cookie. Foreign SQL edits and access revocation are tested.

`tests/parity.py` compares nine scenarios against live Rust and C: all four measured GETs,
three Turbo-frame variants, a room changed through SQL (body, author and boost), and posting.
It compares normalized DOM (all text, elements and attributes), stored message/rich-text/FTS
rows and unread state. It also tests Rust → Mojo → C session-cookie compatibility, expiry,
wrong purpose, tampering, session deletion, notification payloads and broadcast recipients.
Normalization is limited to HTML whitespace, attribute order, asset build fingerprints and
write timestamps. One existing C/Rust difference is recorded explicitly: group initials use
`J+K+J` in C and `J, K, and J` in Rust. Mojo follows Rust. Integration tests add concurrent
writes, malformed HTTP, CSRF, Unicode, cache invalidation and upstream load-generator checks.

## Build and reproduce

Repositories are siblings under `/Users/ruby/Downloads/campfire-test`:
`once-campfire`, `once-campfire-c`, `once-campfire-rust`,
`once-campfire-verification`, and `once-campfire-mojo`.

All measured programs use native ARM64 Linux in Docker Desktop on this Mac. The C port uses
Linux APIs. The server, database, assets and logs are copied onto the VM's native filesystem
before timing. Builds do not run during measurement.

```sh
docker build -f bench/Dockerfile.tools -t campfire-local-tools:latest .
docker run --rm --init -v /Users/ruby/Downloads/campfire-test:/workspace \
  campfire-local-tools:latest bash /workspace/once-campfire-mojo/bench/build.sh
bash bench/test.sh
bash bench/run-durable.sh
```

The existing canonical seed is `../once-campfire-verification/fixtures/default`; only copies
are used. `bench/run-durable.sh` runs the parity gate automatically before collecting measurements.
The unmodified upstream load generator validates every response; its acknowledged-write
validator audits every returned message ID, exact body, room and FTS entry. Failed gates or
invalid responses abort the comparison.

Default method: 16 keep-alive HTTP/1.1 clients, gzip, three rotating-order rounds,
2-second warmups and 8-second samples, medians. Server processes (including background jobs)
share VM CPUs `0-3`; the client uses `4-7`. Each application gets a 64 MiB response-cache budget
and upstream C/Rust retain other caches. These are VM CPU assignments, not physical-core
pinning. Reads repeat warm-cache requests by one user; mixed-user chat, cold rendering and
WebSocket fanout are different workloads.

## Source and license

Routing, request parsing, sessions, SQL, render models, rich-text policy, job policy and the
nonblocking HTTP loop are Mojo. No Python runtime, Rust Campfire library or C Campfire
application is linked into or launched by the server. `native/platform.c` supplies generic
POSIX, process-shared queue, SQLite, zlib, libxml2 and OpenSSL ABI adapters. The same vendored SQLite
3.53.4 source as the C build is used. Python is used only for build-time template generation,
benchmark orchestration, tests and offline import/backup tools.

Templates are adapted from the MIT-licensed Basecamp Rust/Rails implementations. Their
source expressions are mapped in `tools/import_templates.py`; regular builds use the vendored
`templates/` and `assets/` inputs through `tools/compile_templates.py`. Retain `MIT-LICENSE`.

Source counts can be reproduced in the toolchain container with `python3 bench/count_source.py bench/results/recount` (requires all three sibling checkouts and the shared verification repository).

## Historical local HTTP results (posting comparison withdrawn)

| HTTP workload (requests/sec) | Rust | C | Mojo |
|---|---:|---:|---:|
| Room page | 64,210 | 77,241 | 107,296 |
| Messages page | 61,190 | 77,626 | 123,218 |
| Sidebar | 67,116 | 80,770 | 131,318 |
| Search | 68,367 | 79,781 | 127,550 |
| Post a message | 5,805 | 3,669 | 1,869 |
| Backend KLOC | 30.7 | 94.7 | 6.7 |

Median of three rounds on Apple M4 (24 GiB RAM), native ARM64 Linux in Docker Desktop. The HTTP/parity gates passed, but a later log audit found C dropped jobs and Mojo shutdown errors; 341,625 writes were individually audited. Mojo completed 54,921 jobs without errors or drops.

Locally recounted backend source: 5,835 Mojo + 637 generic C adapters + 260 executable template lines = 6,732. Rust and C were recounted from the measured checkouts too; these supersede the source counts quoted from older upstream README revisions. See `source-count.json` for the common counting method and exclusions.

Raw receipts, all rounds, compiler/image/source hashes and acceptance logs: `bench/results/2026-10-09-m4-full/`. This table measures five warm HTTP workloads, not every implemented feature.

## Posting investigation — 2026-10-10

The historical C runs dropped 26,824, 25,386 and 25,282 push jobs. Successful HTTP/SQL checks did not establish equal completed background work. Rust and C also have weaker job durability than Mojo. Do not use the old posting row as an equal-work language comparison. The runner now rejects job-drop and runtime-failure logs, including shutdown.

Profiling and controlled variants are described in [bench/POSTING_DIAGNOSIS.md](bench/POSTING_DIAGNOSIS.md). The current implementation preserves durable jobs, copies UTF-8 spans during JSON encoding, reuses the encoded broadcast payload, skips disabled audit-payload construction, and exits forked workers after worker-local cleanup without tearing down the inherited parent runtime.

Those previously outstanding items are now implemented and tested: disk-spooled uploads with a 10 GiB default limit, both Linux architectures, local Disk import, and actual Chrome/FCM delivery. The current durable comparison is documented above and in PORT_STATUS.md. C upstream explicitly does not support migrating existing installations.
