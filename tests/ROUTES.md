# Route and workflow audit

Reference: checked-out Rails `config/routes.rb` and the implemented actions in every controller, at `b52b244`. Rails declares REST resources with unused actions too; those declarations are not additional product features.

| Area | Implemented workflows | Acceptance evidence |
|---|---|---|
| Installation and sessions | First run, invites, bcrypt login/logout, return URL, transfer links/QR, rate limiting, cookie migration | Browser smoke, full 19/21/28/99, signature/encrypted vectors, sessions, imported fixture |
| People and account | Profile/avatar, logo, account permissions, join-code rotation, custom CSS, paginated members, roles/deactivation, bans/recovery | Browser smoke, full 4/18/19/20/28 |
| Rooms | Open/closed/direct creation, edits, membership changes, permissions, deletion, settings, notification involvement, autocomplete | Browser smoke, full 5/6/19/22/28, parity |
| Messages | Paging, permalinks, creation, edits, deletion, boosts, search/history, refresh, conditional GETs | Browser smoke, integration, parity, full 8/11/16/23/29/30 |
| Rich text | Presentation, plain text, editing, bot HTML, mentions, legacy Trix, sounds, guarded previews | Current Rails 658-case corpus, full 8/12/23/30 |
| Realtime | Action Cable handshake/subscriptions, room/user/room-list streams, presence, typing, revocation, fragmented frames, bounded queues | Browser smoke, full 6/13/15, recovery, HTTPS/WSS |
| Files and media | Multipart/direct upload, checksum, signed blob/disk/representation URLs, proxy/redirect, streaming, HEAD/ranges, thumbnails/posters, cleanup | Full 2/3/4/10/14/17/22/24/26/27/30/31, streaming_uploads, mixed_workloads |
| Bots and push | Bot management/key rotation, API paging/writes/boosts, webhook replies, encrypted push, subscription/test/delete, delivery retries | Full 9/10/19/25, independent TLS retry/decryption, crypto vectors, recovery |
| PWA and assets | Manifest, service worker, compiled frontend assets and icons | Browser smoke, full 1, HTTPS package tests |
| Operations | Worker supervision, persistent jobs/keys, Docker/Caddy, integrity, import, backup/restore, failed-job retry | Recovery, storage_recovery (all job kinds), operations, read-only imported fixture, package tests |

The scope is the complete application, not five benchmark endpoints. Equivalent workflows do not imply byte-identical generic settings forms, identical implementation internals, or validation of every possible deployment and external push service. Deployment limits and documented behavioral differences are in `PORT_STATUS.md` and `DEPLOYMENT.md`.

Security findings A1–A10 map to `replacement.py`, `network_failures.py`, `mixed_workloads.py` and the two-user browser gate; see `PORT_STATUS.md` for each assertion.
