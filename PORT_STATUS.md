# Application replacement status

The port covers core Campfire workflows, but full replacement parity is not yet established. Large multipart upload parity with Rust, amd64 packaging/validation, and external browser push acceptance remain unfinished. It is a standalone compiled Mojo server with its own routing, authorization, SQL, rendering, Action Cable, storage and delivery policy. It does not embed or launch the Rust or C Campfire applications. Everything remains local; no repository has been published.

## Implemented and verified

- Setup, invitations, login/logout, shared per-IP login limits, signed return links, profile/account settings, avatar/logo uploads, account restrictions, invite rotation, device-transfer QR codes, administration, moderation and paginated user management.
- Open, closed and direct rooms; membership changes and revocation; messages, edits, deletion, boosts, search, permalinks, unread state, typing/presence, fragmented WebSocket frames and live Action Cable fanout.
- Binary multipart/direct uploads, checksum validation, signed blob/disk/representation URLs, single/multiple byte ranges, conditional responses, Unicode download filenames, streamed files, image/video/PDF previews and database/file cleanup. A 160 MiB stored file passes full-download checksum, HEAD, range and keep-alive checks. A conventional MP4 with a trailing `moov` atom passes analysis and poster generation through a seekable input.
- Rich-text presentation, plain text, editor serialization, Action Text API/webhook HTML, verified mentions, legacy Trix/old signed mentions, sounds, guarded OpenGraph previews, bot API and webhook replies. Editing retains formatting metadata and rebuilds custom attachments from their records.
- Web Push encryption and VAPID, independently checked against RFC 8291 ciphertext and an independent receiver/signature verifier.
- Process supervision, durable SQLite jobs, retries, per-recipient receipts, failure isolation, leases and whole-process crash/restart recovery.
- Standalone non-root Docker deployment with vendored SQLite, bounded connections/buffers, Caddy TLS/HTTP2/WSS, persistent keys, backup/restore, integrity checks, failed-job retry and copying imports from an existing local Disk installation.

The route inventory and evidence mapping are in [tests/ROUTES.md](tests/ROUTES.md).

## Acceptance evidence

The final source passes 32 application tests, 10 benchmark-contract/concurrency tests, nine live DOM/database/cookie/delivery scenarios against Rust and C, a whole-process crash/restart test and two operations tests. Both the original upstream 658-input rich-text corpus and a newly generated 658-input Rails corpus pass, with 54 preview URLs in each. The new corpus additionally compares all editor values and all Action Text body HTML, including nested JSON/HTML attachment payloads. Plain text, rendered DOM, verified mentions and output security invariants are checked independently.

Ruby-generated variation digests, 70 Rails signature/purpose/expiry vectors, the exact RFC 8291 encryption vector and independently verified VAPID/decryption tests pass. The final packaged image passes the shared upstream Chromium smoke flows, certificate-verified HTTPS signup, secure session-cookie flags, authenticated WSS and HTTP/2. The original shared Rails fixture was copied without changing its rows, objects or keys, and existing sessions/passwords, room history, search, profile and avatars work in the packaged application.

## Explicit differences and operational limits

- This is a functional replacement, not a claim that every generic settings form is byte-identical or every possible deployment has been exercised. The five benchmark response contracts and nine differential DOM scenarios are independently checked.
- Like Rust, missing mentions render a marker instead of blanking an entire message, missing editor attachments are omitted, DOM-clobbering `name` attributes are removed, and attribute brackets are escaped before autolinking. These are explicit exceptions in the fixture checker, not arbitrary ignored cases.
- The current deployment target is ARM64 Linux, including Docker Desktop on Apple silicon. A native macOS server build is not supplied; the C comparison also requires Linux.
- Upload requests are limited to 64 MiB. Downloads stream in 64 KiB chunks. Media processing buffers at most 128 MiB of input and uses pixel/dimension, memory and time limits. Unpreviewable files remain downloadable. Only the transformations used by this Campfire application are supported.
- Import supports the original local Active Storage Disk layout. Remote object storage must be exported to a consistent local installation first. An explicit option preserves and reports pre-existing orphaned records; corrupt/missing attached files still fail import.
- Live delivery through a real external browser push-service account was not exercised. Cryptography, payloads, recipient selection, endpoint guards, retry policy and a receiver are tested. External HTTP delivery is at-least-once: a crash after remote acceptance but before a local receipt can cause a duplicate.
- The copied Rails schema and signing/VAPID keys are preserved, with additional Mojo job tables. Migration is a stopped-source copy, not a dual-writer or replication system. See [DEPLOYMENT.md](DEPLOYMENT.md).

## Provenance and reference drift

Frontend assets are upstream MIT-licensed build outputs, with four Rust corrections required by the shared browser contract. Gumbo is Nokogiri 1.19.4's pinned dependency (`8cfb9daae9ee4a0837508eab43c40fbc8c4138c9`); QR Code generator and SQLite source/licenses are vendored. Server HTML is generated from templates and live records, never captured responses.

The checked-out Rails app is `b52b244`; Rust is `6dae2fd` and embeds an older Rails reference (`90b3300`); C is `873a51f`. Current Rails preserves an existing non-direct unread timestamp, limits unread broadcasts to unread/connected memberships and removes rooms asynchronously. Mojo follows current Rails. These reference differences mean Rust, C and Mojo must not be presented as three identical full applications, even when the five measured HTTP contracts match.

## Audit correction — 2026-10-10

The earlier completeness wording overstated the evidence. The benchmarks checked HTTP/SQL effects, but C dropped 77,492 push jobs across its three historical rounds. Mojo also used durable SQLite job/receipt storage while both references used memory queues. The historical posting rates therefore do not establish equal completed work. The audit additionally found errors while forked Mojo workers tore down the inherited runtime at shutdown. That path is fixed and has a new graceful-shutdown regression check. See `bench/POSTING_DIAGNOSIS.md` for measurements, the JSON/broadcast fix, and exact remaining boundaries.
