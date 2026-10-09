# Full replacement work log

Implementation and acceptance testing are in progress. The requested scope is a complete application replacement, superseding the original five-workload limit. All work remains local; there is no published Mojo repository.

## Implemented and tested

- Setup, invitations, login/logout, shared per-IP login limits, signed return links, profile/account settings, avatar/logo uploads, account restrictions, invite rotation, device-transfer QR codes, administration, moderation, and paginated user management.
- Open, closed, and direct rooms; membership changes and revocation; messages, editing, deletion, boosts, search, permalink navigation, unread state, typing/presence, fragmented WebSocket frames, and live Action Cable fanout.
- Binary multipart/direct uploads, checksum validation, signed blob/disk/representation URLs, single and multiple byte ranges, conditional responses, actual image decoding, video analysis/posters, stored variants, and recursive database/file cleanup.
- Safe rich-text presentation and plain-text conversion, legacy Trix input, old signed mentions, rich-text editor rebuilding, sounds, guarded OpenGraph previews, bot API and webhook replies.
- Web Push encryption and VAPID, independently checked with the RFC 8291 ciphertext and an independent receiver/verifier. This does not claim a real browser push-service account was exercised.
- Process supervision, durable SQLite delivery jobs, retries, per-recipient receipts, failure isolation, leases, and whole-process crash/restart recovery. External HTTP delivery is at-least-once: a remote service can receive a duplicate if the server crashes after remote acceptance but before the local receipt commits.
- Standalone non-root Docker deployment with vendored SQLite, bounded connections/buffers, Caddy TLS/HTTP2/WSS, persistent keys, backup/restore, integrity checking, failed-job retry, and copying imports from an existing local Disk installation.

## Acceptance evidence

The local suite currently includes 26 application tests, 10 benchmark-contract/concurrency tests, nine differential live DOM/database/cookie/delivery scenarios against Rust and C, and a whole-process crash/restart scenario. The new application tests pass. The shared upstream Chromium smoke assertions have passed an earlier standalone build; they are being repeated after the latest editor/admin/storage changes.

The Rails-generated rich-text corpus covers 658 inputs and 54 preview URLs. Plain text, rendered DOM, verified mentions, and URI validation have independent comparisons, plus checks that rendered output contains no active script, event attributes, unsafe URLs, or DOM-clobbering attributes. Deliberate rendering differences follow Rust: escape attribute brackets before autolinking, remove `name` attributes, and render a deleted-user mention as a missing-attachment marker instead of blanking the message. This is not yet a complete fixture comparison of editor serialization and bot HTML.

Ruby-generated variation digests and Rails signature fixtures supplement the application tests. Cryptographic vectors, shared verification tooling, backup/restore, certificate-verified HTTPS signup, authenticated WSS, and HTTP/2 have separate receipts in the local work directory. Final receipts will be saved with the expanded-build benchmark results.

## Remaining acceptance work

- Finish the current signature/corpus gates and import a real shared fixture into the standalone deployment.
- Repeat browser, TLS/HTTP2, media and operational checks on the final packaged image.
- Complete the route/form and rich-text editor/body-HTML audit. Generic forms still differ in markup from some upstream templates.
- Verify less common media and large-file behavior. Uploads are currently capped at 64 MiB; file responses are buffered and capped at 128 MiB. This is a material difference for installations with larger existing files.
- Rerun and record the five README benchmarks on the final source, along with updated source counts and limitations.

Do not describe this intermediate checkpoint as a complete drop-in replacement or use the historical benchmark table as a measurement of it.

## Provenance and reference drift

Frontend assets are upstream MIT-licensed build outputs, with four Rust corrections used by the shared browser contract. Gumbo is Nokogiri 1.19.4's pinned dependency (`8cfb9daae9ee4a0837508eab43c40fbc8c4138c9`); QR Code generator and SQLite have vendored source and licenses. Server HTML is generated from templates and live records, never captured responses. No Rust or C Campfire server is embedded or launched by Mojo.

The checked-out Rails app is `b52b244`; Rust is `6dae2fd` and embeds an older Rails reference (`90b3300`); C is `873a51f`. Current Rails preserves an existing non-direct unread timestamp, limits unread broadcasts to unread/connected memberships, and removes rooms asynchronously. Mojo follows current Rails for those behaviors. The ports therefore cannot be presented as three identical full applications, even when the five HTTP workload contracts match.
