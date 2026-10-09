> Historical profiling note. The listed large-upload, second-architecture and real-browser push gaps have since been implemented and validated. The current README contains the new equal-durability, completed-work comparison and supersedes earlier posting comparisons.

# Campfire posting investigation — 2026-10-10

The previous “all gaps closed” wording was too strong. The implementation has substantial application coverage, but specific deployment, upload and acceptance gaps remain. The earlier C posting comparison also failed to account for dropped background jobs. This report corrects that claim and records the investigation and fixes.

## Posting result with durable jobs preserved

| Same-machine paired test | Median posts/sec | Three runs |
|---|---:|---|
| Original Mojo | 1,984 | 2,006, 1,939, 1,984 |
| Optimized Mojo, durable jobs retained | 2,882 | 2,882, 1,603, 2,888 |

The measured improvement is 45.3%. These are new posting-only paired runs, not replacements for the earlier four GET measurements. All responses passed the upstream validator, every acknowledged write was audited against SQLite/FTS, and all Mojo notification jobs drained with zero errors or drops. The optimized runs also passed the new shutdown/server-log gate. One of the first three optimized runs was an outlier at 1,603 posts/sec; four follow-up runs measured 2,879, 2,872, 2,788, 2,882 posts/sec, all with clean logs and fully drained jobs. Sampling established connection counts showed uneven distribution across workers, but the four follow-up rates stayed close, so that observation does not establish the cause of the earlier outlier.

## Causes established by profiling

1. SQLite job bookkeeping and writer contention. The original four HTTP workers and three job workers contend for the same SQLite writer. For each fixture message, the job adds approximately nine background transactions: claim, unread receipt, three lease renewals, three push receipts, and cleanup. Rust and C use non-durable in-memory job queues instead. The separate instrumented run spent about 1.28 ms per request in the two foreground BEGIN IMMEDIATE calls, versus only 4.9 microseconds of CPU. That is elapsed waiting/descheduling inside the lock-acquisition calls, not JSON or message rendering time.

2. Expensive JSON/broadcast preparation. Broadcast/audit preparation consumed about 70% of foreground request CPU (611 microseconds per post). The old JSON encoder allocated a small String for every codepoint. The broadcast path encoded the whole HTML body twice, constructing an audit argument even when audit logging was disabled. The fix copies intact UTF-8 spans between ASCII escapes, reuses the encoded payload, and constructs audit data only when enabled. It preserves the JSON escaping policy and actual broadcasts.

3. An extra outer write transaction. The request dispatcher takes a writer lock, commits, then post takes it again. A diagnostic build skipping the outer transaction measured 1,960 versus 1,916 posts/sec, only 2.3% apart and within the run variation. It is avoidable work, but it does not explain most of the deficit.

In a separate diagnostic comparison, retaining the payload/recipient/notification work but replacing durable jobs/receipts with a memory queue raised original Mojo from 1,916 to 3,069 posts/sec. That variant passed the HTTP/DOM/SQL and notification-counter checks but deliberately loses crash recovery; it was never installed in the app repo. Reducing HTTP workers from four to one made throughput worse (1,045), so reducing worker count is not a solution. After the JSON fix, the remaining priority is coordinating/batching durable SQLite bookkeeping while preserving crash recovery, rather than silently removing that work.

## Correction to the C comparison

The original C server logs contain 77,492 dropped push jobs: 26,824, 25,386, 25,282 in rounds 1–3. This is about 70% of its 111,081 acknowledged messages across warmup and timed posting. The queue capacity was 128 and C used its own default two job workers per kind; JOB_CONCURRENCY=3 configures Rust/Mojo, not C. Message persistence succeeded, but a successful response did not mean equivalent notification work completed. C's reported posting rate therefore must not be used as an equal-completed-work comparison. Fresh diagnostic C runs reproduced the drops. Rust's sampled logs did not show drops, but its queue also has weaker crash durability than Mojo's.

The benchmark now rejects known job-drop, worker/request-failure and runtime-crash log patterns after shutdown. A quiet log alone does not prove per-job completion in Rust/C; their work still requires explicit completion instrumentation for a strict comparison. Historical raw measurements and logs are retained as evidence, with a correction attached.

## Why the remaining boundaries were left, and how the ports compare

| Item | Rust checkout | C checkout | Mojo assessment |
|---|---|---|---|
| Platform | Production images target Linux amd64 and arm64. | Linux-specific epoll implementation; built for ARM64 here. | Only ARM64 Linux/Docker validated. This met the local M4 comparison target, but amd64 packaging/validation remains a real gap relative to Rust. Native macOS was not established as a requirement met by both references. |
| Large uploads | Multipart files spool to disk; default whole multipart cap is 10 GiB. Non-multipart bodies are capped at 16 MiB. | Decoded HTTP request-body cap is 16 MiB. | Entire upload requests are bounded at 64 MiB in memory. More generous than C's cap, but a real gap relative to Rust's large multipart uploads. Raising the constant alone is insufficient: streaming/spooling is needed. |
| Local Disk migration | Uses the existing Rails database/Disk layout and preserves keys/cookies. | Uses Disk storage; README explicitly says existing installations and schema upgrades are unsupported. | Copying migration was implemented and tested, including sessions/passwords/files. Disk-only storage is shared by the ports; an S3/GCS adapter is not a missing feature relative to these two implementations. |
| External Web Push delivery | Implemented; includes crypto vectors and TLS fake-service/receiver tests. | Implemented; includes vectors/receiver tests and an optional real browser subscribe-and-deliver path (CF_E2E_PUSH=1). That path can report a missing prerequisite when the browser cannot subscribe. | Encryption, VAPID, delivery and local receiver tests exist. A real browser subscription followed by external delivery has not been run for Mojo. This is unfinished acceptance coverage, not an unnecessary test or missing push transport. |

I stopped at bounded local implementation and local acceptance coverage, then described completion too broadly. Those choices were not requirements you waived. The large-upload, platform-packaging and live-push acceptance items should have remained explicit open work, not been presented as “all gaps closed.” The source evidence does not establish that every optional real-service test has actually passed in the Rust/C checkouts either.

## Fixes and verification

The local app retains durable jobs. It now has the JSON/broadcast optimization, a benchmark server-log gate, and a graceful forked-worker shutdown fix. The prior workers could enter the inherited parent Mojo runtime's global teardown and emit runtime stacks during shutdown. Worker-local cleanup now finishes before a child-specific exit; the parent owns global runtime teardown. A new regression test posts messages, drains jobs, and requires a clean shutdown within three seconds.

Validation passed: 1,008 independent JSON round trips including every ASCII control, non-ASCII text, emoji, empty and large strings; the Rails rich-text/editor/API HTML corpus; Rails signature and Web Push vectors/independent receiver; 32 application tests; 10 integration tests; nine live Rust/C differential scenarios; crash/restart recovery; and the new graceful-shutdown test. The experimental memory-queue and dispatcher-bypass code remain only in the scratch study.

Source evidence: Rust README and crates/kit/src/body.rs, crates/storage/src/storage.rs, crates/db/src/database.rs, crates/campfire/src/jobs.rs and integrations/web_push/tests.rs; C README, src/http/http_internal.h, src/jobs/jobs.h and tests/integration/cases/e2e_02.py; Mojo src/app.mojo, src/jobs.mojo, src/crypto.mojo and native/platform.c. Revisions and source/log hashes are preserved in the accompanying JSON.

Method: native ARM64 Linux in Docker Desktop on the same Apple M4, four server VM CPUs and a separate four for the client, 16 HTTP/1.1 keep-alive clients, gzip, 2-second warmup and 8-second timed samples. Three alternating rounds with fresh identical fixture copies. Notification endpoints are the same locally rejected endpoints; no active Cable subscribers. Phase profiling ran separately and adds overhead; phase/SQL totals overlap and are not additive. These diagnose implementations and configurations, not intrinsic language speed.
