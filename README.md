# Campfire in Mojo — five matched benchmark workloads

A native, compiled Mojo 1.1 port of the five HTTP workloads in the Campfire README:
room pages, paginated messages, sidebar, search, and posting a text message.
This repository stays local. It is not a complete Campfire replacement.

## What now matches

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
- **Background work in this benchmark:** three workers build room notification payloads,
  select recipients, count badges, and apply the upstream push endpoint guard. All three
  apps receive the same local endpoints, which the upstream guard rejects before network
  delivery or encryption. The harness checks that every queued Mojo job completes, without
  errors, queue drops, or unsupported delivery branches.
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

## Scope of the equality claim

The matching claim covers **the measured fixture, requests and background branches**. It
is an implementation comparison under those conditions, not a language-only test or full
application parity. Rust and C still implement many more features, so KLOC is not comparable
as equal-feature application size.

There are zero Action Cable subscribers in the HTTP workload. Mojo prepares the same event
payloads but does not implement WebSocket delivery. The measured plain text posts mention no
bots, and the destination guard blocks all push endpoints. Public push transport, bot webhook
delivery, attachment/media processing, general Action Text mentions/embeds, sound messages,
administration, asset serving, TLS and a complete interactive frontend remain outside this
port. The compiler includes the layout's asset references; the application does not yet serve
those resources. This is a benchmark backend, not a production server.

The rich-text path preserves basic formatting and sanitizes using a Mojo allowlist over a
generic libxml2 DOM adapter; it does not claim full Rails HTML5/Action Text compatibility.
The strict comparison gate is rerun before each benchmark so changed fixtures do not silently
inherit a passing result. The historical abbreviated-body measurements remain in
`bench/results/2026-10-09-m4/` for provenance.

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
bash bench/run.sh
```

The existing canonical seed is `../once-campfire-verification/fixtures/default`; only copies
are used. `bench/run.sh` runs the parity gate automatically before collecting measurements.
The unmodified upstream load generator validates every response; its acknowledged-write
validator audits every returned message ID, exact body, room and FTS entry. Failed gates or
invalid responses abort the comparison.

Default method: 16 keep-alive HTTP/1.1 clients, gzip, three alternating-order rounds,
2-second warmups and 8-second samples, medians. Server processes (including background jobs)
share VM CPUs `0-3`; the client uses `4-7`. Each application gets a 64 MiB response-cache budget
and upstream C/Rust retain other caches. These are VM CPU assignments, not physical-core
pinning. Reads repeat warm-cache requests by one user; mixed-user chat, cold rendering and
WebSocket fanout are different workloads.

## Source and license

Routing, request parsing, sessions, SQL, render models, rich-text policy, job policy and the
nonblocking HTTP loop are Mojo. No Python runtime, Rust Campfire library or C Campfire
application is linked into or launched by the server. `native/platform.c` supplies generic
POSIX, process-shared queue, SQLite, zlib, libxml2 and OpenSSL ABI adapters. The same SQLite
3.53.4 archive as the C build is linked. Python is used only for build-time template generation,
benchmark orchestration and tests.

Templates are adapted from the MIT-licensed Basecamp Rust/Rails implementations. Their
source expressions are mapped in `tools/import_templates.py`; regular builds use the vendored
`templates/` and `assets/` inputs through `tools/compile_templates.py`. Retain `MIT-LICENSE`.

## Local matched-workload results

| HTTP workload (requests/sec) | Rust | C | Mojo |
|---|---:|---:|---:|
| Room page | 59,248 | 71,809 | 120,025 |
| Messages page | 52,539 | 69,406 | 121,129 |
| Sidebar | 65,428 | 73,096 | 127,186 |
| Search | 64,584 | 69,028 | 110,914 |
| Post a message | 5,545 | 3,375 | 3,592 |
| Backend KLOC | 30.7 | 94.8 | 2.4 |

Median of three rounds on this Mac. All nine parity-gated runs passed; 379,185 writes were individually audited.
Mojo completed 104,518 notification jobs without errors or drops.

Backend KLOC: 1,979 Mojo + 224 generic C ABI + 245 executable template lines = 2,448. Generated code and plain HTML are excluded, following the upstream counting rule. This remains a smaller feature scope than the full Rust/C applications.

Raw receipts, parity comparisons, per-round rates and source hashes: `bench/results/2026-10-09-m4-matched/`.
