# Campfire in Mojo — initial benchmark port

A local, compiled Mojo 1.1 implementation of five [ONCE Campfire](https://github.com/basecamp/once-campfire)
HTTP workloads: room pages, paginated messages, sidebar, search, and posting a text message.
This is the benchmark-first scope, **not a complete Campfire replacement**. Nothing has been published.

## Implementation

Routing, HTTP parsing, authentication/session handling, authorization, SQL queries, rendering,
cache management, and the nonblocking connection loop are written in Mojo. There is no Python
runtime in the server. `native/platform.c` is a small generic ABI adapter for POSIX sockets/poll/fork,
SQLite, zlib, crypt_r bcrypt, and OpenSSL randomness. The C and Rust Campfire applications are
neither linked into nor invoked by the Mojo server. The benchmark build links the same pinned
SQLite 3.53.4 archive as the C implementation; Python runs orchestration and tests only.

The server uses four processes sharing one SQLite WAL database. Every authenticated read checks
the session, active user, and room membership in a read transaction. A 64 MiB total response-cache
budget is divided among workers. SQLite `data_version`, explicit local invalidation, and a
15-second lifetime control cache reuse. Tests cover foreign SQL edits and access revocation.
Message rows, rich-text rows, full-text entries, room counters and unread markers are written
atomically. SQL arguments are bound parameters.

## Build and reproduce on this Mac

All repositories are siblings under `/Users/ruby/Downloads/campfire-test`:

```
once-campfire/
once-campfire-rust/
once-campfire-c/
once-campfire-verification/
once-campfire-mojo/
```

Docker Desktop runs native Linux ARM64 on the local Apple M4. Linux is required by the upstream
C implementation and this initial port's POSIX adapter. The isolated macOS `.venv` also contains
Mojo 1.1.0, but measurements use the Linux compiler and binaries for all implementations.

From this repository:

```sh
docker build -f bench/Dockerfile.tools -t campfire-local-tools:latest .
docker run --rm --init -v /Users/ruby/Downloads/campfire-test:/workspace \
  campfire-local-tools:latest bash /workspace/once-campfire-mojo/bench/build.sh
bash bench/test.sh
bash bench/run.sh
```

The canonical seed already exists at `../once-campfire-verification/fixtures/default`.
To generate it again at a new destination, use the upstream `bin/seed` and the exact Rails
revision `90b330024dec3e757c79b6a7e6568f93da8e3148`:

```sh
docker build --build-arg APP_VERSION=verification \
  --build-arg GIT_REVISION=90b330024dec3e757c79b6a7e6568f93da8e3148 \
  -t campfire-reference:local ../once-campfire-rust/reference
PATH=/opt/homebrew/opt/sqlite/bin:$PATH ruby ../once-campfire-verification/bin/seed \
  --image campfire-reference:local --output ../once-campfire-verification/fixtures/new-seed
```

The upstream fixture builder refuses to overwrite an existing seed. The macOS system SQLite
CLI failed its read-only integrity check on this machine; Homebrew SQLite passed.
Fixture credentials are disposable and remain in the ignored fixture tree. Use only copies of
the fixture database: this port creates `mojo_sessions` and adds the room counter when needed.

## Benchmark method

- Five routes from the README table, 16 concurrent HTTP/1.1 keep-alive clients, gzip enabled.
- Three rounds with alternating application order; each route has a 2-second warmup with four
  clients and an 8-second measurement with 16. Report the median of the three measurements.
- Server affinity `0-3`; load-generator affinity `4-7`, within Docker's Linux VM. These are VM
  CPU assignments, not a claim of fixed physical performance-core affinity on macOS.
- One server runs at a time. Runtime binaries, C assets, logs, database and uploads are copied
  to the same native Linux filesystem before timing. No build runs during measurement.
- Response caches total 64 MiB per app. Rust and C retain their other upstream caches.
- Request access logs are disabled. Rust/C background jobs still run; fixture webhook and push
  endpoints are changed to the local closed port 9. Mojo has no background delivery system.
- `bench/local.py` adapts process launch to this local VM and selects only the five requested
  contracts. The upstream Rust load generator and acknowledged-write audit are unmodified.
- Expected message IDs, ordering and content come independently from fixture SQL. All measured
  responses must pass the upstream `route-contract-v1` validation. Every warmup and timed write
  is audited by exact returned ID, body, room and search-index entry, with total-count and SQLite
  integrity checks. Invalid responses fail the run and never enter the final table.

Read-only results describe warm-cache repeated requests by a fixture user. They do not measure
simultaneous active chat users, WebSocket fanout, or mixed traffic. Raw receipts and contracts
are stored in ignored `bench/results/` along with source and binary hashes.

## Scope and comparison limits

**The Mojo column is a partial implementation with less work per request. It is not a
language-only speed comparison or evidence of equivalent application performance.**
Mojo produces shorter, text-focused HTML. It flattens rich text; it has separate random,
server-side 24-hour session cookies instead of Rails-compatible signed/encrypted cookies.
Posting persists the message and index but does not broadcast or deliver push notifications
and webhooks. These differences affect both throughput and source size. The saved report
includes payload sizes so the difference is visible.

Not included: full Rails UI/asset parity, Action Cable, upload/media handling, rich-text mentions,
boosts, bot APIs, user/account/room administration, invitations, existing-cookie migration,
conditional HTTP requests, TLS/ACME, backup/restore automation, production readiness, and
complete upstream browser parity. Pagination returns an empty 200 response for an empty page;
the measured fixture windows are populated. Only GET and form-encoded POST are supported.
The server binds loopback and is intended for this local experiment.

## Validation

`tests/integration.py` runs the compiled server against a fresh canonical fixture copy. It checks
all read contracts, anonymous/tampered/invalid authentication, membership revocation, user
deactivation, foreign body edits, CSRF metadata/origin checks, Unicode and HTML escaping,
64 concurrent writes, SQL/form boundaries, malformed framing, request size bounds and keep-alive.
The shared verification repository's `bin/check` also passes. No claim is made that the full
Rust/C media or browser suites were run.

## License and attribution

MIT; see `MIT-LICENSE`. Application behavior, query windows and benchmark contracts are based
on the public Basecamp Campfire and shared-verification repositories. The original 37signals
copyright notice is retained. The new Mojo code and local test/benchmark adapter are local work.

## Local results

| HTTP workload (requests/sec) | Rust | C | Mojo (partial) |
|---|---:|---:|---:|
| Room page | 59,173 | 73,760 | 231,837 |
| Messages page | 55,289 | 73,036 | 230,464 |
| Sidebar | 64,703 | 78,970 | 241,136 |
| Search | 62,172 | 74,081 | 235,226 |
| Post a message | 5,360 | 3,367 | 8,165 |
| Backend KLOC | 30.7 | 94.8 | 1.0 |

Measured on the local Apple M4 / 24 GiB host using native ARM64 Docker Linux (10 vCPUs, 7.65 GiB VM RAM).
All 9 runs passed response validation and persisted-write audits. These are warm-cache medians, not full-application or language-only parity.
514,508 warmup and measured message writes were individually audited.

Mojo KLOC includes 912 Mojo lines and 137 C ABI-adapter lines (cloc 2.04; Mojo counted using Python comment rules).
Rust/C KLOC uses the upstream counted revisions after verifying their backend sources are unchanged in the cloned HEADs.
Raw results: `bench/results/2026-10-09-m4/summary.json`. The detailed local report includes payload sizes and per-round rates.
