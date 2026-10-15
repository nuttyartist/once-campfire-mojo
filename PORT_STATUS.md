# Replacement contract and acceptance

Publication preparation now includes operator/developer documentation, reproducible
asset verification, packaged notices, version identity, formatting, local release
exports and security checks. [Release status](docs/releases.md) distinguishes
functional acceptance from the unresolved dependency scan, platform acceptance
and deferred maintainer/security contact. This is an unreleased source
candidate for review, not a supported production release.

This port implements the stock Campfire application workflows against the original Rails `b52b244f384456d9ab5892ebb7bebd8cd8c696c9` source and local Active Storage Disk service. It is suitable for upstream review as a functional application port. Passing the documented gates is not a proof of equivalence for every input, deployment or optional Rails extension, nor a substitute for maintainer/security review before a public release.

The [independent upstream gate](docs/upstream-verification.md) now runs the pinned
public harness through a deployment adapter, with unchanged browser/HTTP oracles
and exact durable-job completion checks. Its known intermittent browser
synchronization failure remains visible and fails CI; no retry or test waiver is
applied. See that document for the precise coverage and limitation.

## Audit findings closed

| Finding | Change | Regression evidence |
|---|---|---|
| A1: client-controlled DOM identity | Persisted message and nested Turbo targets use server record IDs; only pending optimistic placeholders reconcile by client ID | `replacement.py`; two-user real Chromium collision/create/edit/delete test |
| A2: Fetch Metadata | Same-origin/same-site policy; missing header allowed only on plain HTTP; bot-key exemptions retained | HTTP and HTTPS positive/negative matrix in `replacement.py`, `network_failures.py` |
| A3: DNS failure counted as delivery | DNS/transient transport failures retry; policy rejection and provider acceptance stay distinct | Real TLS receiver verifies VAPID and decrypts payload across DNS → 503 → 429 → 201; no premature receipt |
| A4: email identity | Signup/profile/login preserve exact Rails identity; no case-folding or merging imported accounts | Mixed-case, whitespace and wrong-case checks |
| A5: commit followed by false failure | Encoded broadcast admission is checked before commit; failed validation rolls back; internal errors return/log 500 | Oversized create/edit and no-partial-write tests; injected media SQL failure rolls back records and prepared files |
| A6: slow work holds SQL writer | Unfurl, bcrypt, push validation/test notification and media preparation run before write transactions; permissions are rechecked on admission | Delayed DNS and real decoder with concurrent writes; retained live Cable frames |
| A7: search punctuation | Unicode word classification and separator normalization applied to search and recent searches | Punctuation/Unicode/empty-query checks |
| A8: attachment-only plain text | One filename-fallback contract for edits, search, APIs, push and webhooks | Replacement/clear-body attachment tests |
| A9: bans break reads/health | GET/HEAD exemption; blocked writes return 429 | Banned-address safe-request and write matrix |
| A10: browser defaults | Framing, referrer and other Rails-equivalent response headers | Header gate and packaged browser/TLS tests |

## Further gaps closed

- Files and parent directories are synced; file deletion intents commit in SQLite and survive worker/process failure. Retried unlink faults and offline garbage collection are tested. Failed speculative file preparation cannot leave committed partial message rows.
- Import checks all 16 original tables/required columns and the maximum supported migration version before accepting data. It supports the current schema and the shared pre-counter schema, installs original room counter triggers and the missing indexes, and rejects older unsupported/newer layouts explicitly. Original source files, committed WAL contents and keys are copied without modifying the source, including from a read-only mount.
- Backup/restore preserve keys, objects, database and the exact accepted pre-existing orphan manifest; restore verifies hashes and publishes a synced destination. Packaged login/history/search/avatar checks run both after import and after restore.
- Rails `_campfire_session` AES-GCM state is supported along with signed `session_token`. Return URLs, purposes, expiry, tamper rejection, unrelated session state and escaped one-time flash are tested with independently generated Rails/OpenSSL data.
- Multipart and signed direct uploads spool to disk. Tests cover 128 MiB multipart, 512 MiB chunked and 80 MiB direct upload, oversize/disconnect paths, checksums, ranges and bounded memory. A 160 MiB download and seek-dependent MP4/PDF/image/audio processing are covered separately. Webhook response capacity now matches the Rust port's 100,000,000-byte cap; a 2 MiB binary reply is verified end to end.
- Current Rails/Lexxy rich text is checked against a newly generated 658-case corpus plus 54 URLs, including plaintext, editor values, body HTML, presentation and mentions. 70 signed and 20 encrypted Rails cookie vectors, variation digests, RFC 8291 ciphertext, independent push decryption and 1,008 JSON round trips are separate gates.
- Clean-checkout bootstrap, standalone tests, native adapter fuzzing under ASan/UBSan, and pinned-action CI for Linux ARM64/amd64 are checked in. No local test depends on a hard-coded personal checkout path or a Rust/C checkout except the optional three-port comparison.
- Worker supervision, message/push/webhook crash recovery, room-removal and banned-history jobs, failed deletion recovery and repeated restart are tested. The benchmark requires exact durable completion on all three local builds.

## Scope and intentional differences

1. The supported deployment is Linux with SQLite and local Disk storage. ARM64 is native on the local M4; local amd64 acceptance runs under emulation. Remote storage adapters, custom Rails plugins, arbitrary historical schema upgrades and a native macOS binary are outside this port's contract. Upgrade an older source with Rails or export remote objects before importing; unsupported data is rejected rather than guessed at.
2. Generic form/error markup is functionally equivalent, not pixel- or byte-identical. Missing rich-text records produce a safe marker/omission instead of making a whole message unrenderable. DOM-clobbering names and unsafe attribute brackets are handled defensively. Corpus exceptions are explicit; arbitrary case names are not skipped.
3. Bounded inputs remain deliberate: 64 KiB extracted message text, 128-byte client IDs, a 1 MiB encoded live event, default 10 GiB decoded upload body, 16 MiB multipart text, 4,096 parts/128 files, and decoder pixel/dimension/time budgets. Oversized live events reject before commit. Only transformations/codecs used by the stock application are provided; unpreviewable files remain downloadable.
4. Media work is synchronous in the HTTP process but is prepared outside the SQLite writer transaction. A busy worker may delay its own existing Cable sockets until it resumes its event loop. Other workers can serve chat, and queued frames are retained within the bounded bus; slow/overrun clients reconnect and resynchronize from durable message history. Live Cable frames are not a durable external-delivery queue.
5. Push/webhook effects are at-least-once. Recipient receipts prevent repeats after a recorded completion; a remote-acceptance/local-receipt crash window can still duplicate a delivery. Transient DNS/transport/5xx/429 failures retain durable retry state. Finite repeated failures become retained failed jobs for inspection/retry. Endpoint-policy rejection is not successful real provider delivery.
6. FULL WAL plus fsynced files/directories and process-crash tests provide a stated durability mechanism and evidence, not a physical power-cut certification of the host/VM/storage hardware.
7. The earlier actual Chrome/FCM service-worker notification acceptance is retained as prior evidence. The fresh automated network gate verifies real encrypted HTTPS transport, retries and provider acceptance using a controlled TLS receiver. It does not claim a fresh test of every commercial push provider.
8. Rust and C embed older Rails behavior; they are comparison subjects, not infallible current-original oracles. The local five-workload comparison uses explicit durability patches. Their unchanged video golden-byte mismatch is recorded in `bench/reference-patches/README.md`.

The full workflow mapping is in `tests/ROUTES.md`. Deployment instructions, limitations and recovery commands are in `DEPLOYMENT.md`. CI runs on native ARM64 and amd64; [hosted results](https://github.com/nuttyartist/once-campfire-mojo/actions/workflows/ci.yml) identify the tested commits and any failures. Source publication does not imply a supported binary release.
