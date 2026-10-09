# Full replacement work log

Status: implementation in progress; not a complete or production-certified replacement.
All work is local. The requested scope is full application replacement, superseding the original five-workload limit.

## Verified so far

- Nine differential live DOM/database/cookie/background-work scenarios against the checked-out Rust and C ports pass on the expanded build.
- Shared upstream Chromium smoke assertions passed after first-run setup, two-tab message delivery, stored-markup safety, edits/search, account/profile updates, decoded QR codes, rooms, bots, custom CSS, session transfer, joining and direct-message autocomplete. The local runner uses installed Playwright 1.62.1; upstream specifies 1.63.0. This is not a screenshot-equivalence claim.
- Nine additional application integration tests pass: static assets, binary multipart/download/ranges, direct-upload checksums, decoded avatar output, private-room conversion denial, fragmented Cable/fanout/access revocation, cross-origin mutation rejection, signed mentions/sounds, and a real disposable local webhook round trip.
- Web Push encryption matches the published RFC 8291 ciphertext vector. External push delivery and VAPID interoperability are not yet independently verified.

## Added since those broader browser assertions

Bot pagination, bot boosts, bot attachments, message permalinks, empty-account handling, OpenGraph fetch/embeds, DNS-pinned restricted network transport with bounded resolution, shared per-IP login limits, secure cookies for configured HTTPS, peer-IP tracking, durable jobs with leases/retries/delivery receipts, and worker supervision. The nine integration tests and nine differential scenarios still pass after these changes. Dedicated tests for these newest behaviors are being added.

## Open gaps that prevent a full-replacement claim

- Media analysis, video posters, stored variants, exact Active Storage representation/digest compatibility and cleanup lifecycle.
- Complete rich-text/legacy attachment/CSS sanitizer equivalence and broader adversarial cases.
- Exact HTML/forms and route/status coverage beyond the validated browser journey and nine DOM scenarios.
- HTTP streaming/framing coverage, conditional cache/range responses, and a reproducible standalone deployment with HTTPS/HTTP2.
- Independent push receiver/VAPID tests, worker crash/restart/delivery recovery tests, and operational backup/migration/restore tooling.
- Broad shared verification suite execution, build/runtime resource limits, and new performance measurements after feature completion.

## Source provenance

Frontend assets are upstream MIT-licensed source build outputs copied from the local C reference snapshot, with four Rust frontend corrections used by the shared browser contract. Gumbo is the C port's pinned Nokogiri 1.19.4 dependency, commit 8cfb9daae9ee4a0837508eab43c40fbc8c4138c9; its licenses are in vendor/gumbo. QR Code generator is the same C port vendored dependency; its license is in its source. No captured server responses are compiled into the application. No Rust or C Campfire server is embedded or launched by Mojo.

Do not use the historical benchmark table as a measurement of this expanded build.
