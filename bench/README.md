# Local performance comparison — 2026-10-10

<!-- BENCHMARK_BEGIN -->
| Workload (completed requests/sec) | Rust* | C* | Mojo |
|---|---:|---:|---:|
| Room page | 44,403 | 55,590 | 55,743 |
| Messages page | 41,337 | 55,509 | 59,515 |
| Sidebar | 50,500 | 59,726 | 62,094 |
| Search | 49,577 | 62,785 | 59,204 |
| Post a message | 1,180 | 382 | 1,090 |
| Backend KLOC | 30.9 | 94.8 | 8.0 |

**256,162 messages and 768,486 recipient completions audited across timed runs and warmups. No missing messages, FTS rows or receipts; no pending, failed or dropped jobs.** Posting rounds (completed messages/sec): Rust: 1,190, 1,107, 1,180; C: 278, 382, 401; Mojo: 1,101, 1,090, 1,018. Raw results: `bench/results/2026-10-10-m4-posting-optimized/`.

Measured commits: Rust `aea2e0768426`, C `f5db6695873b`, Mojo `3b7440dc3f84`.
<!-- BENCHMARK_END -->

The tracked [comparison summary](acceptance/2026-10-10-posting-optimized.json) records every round, binary hash, completion audit and validation gate. Raw acknowledgement files are local and excluded from Git. Previous comparisons are preserved separately.

A separate paired old/new/new/old experiment measured median completed posting rates of 796.4 before and 1,105.0 after: 38.8% higher. Its four runs retain all acknowledgements and exact receipts; it is not mixed into the nine-run table.

These are **local durability-patched Rust and C builds**, not stock upstream performance claims. Every application uses SQLite WAL `synchronous=FULL`, atomic message/outbox admission, persisted retry state, recipient receipts and a 10-second SQLite write-lock budget. Posting throughput includes the final queue drain. The harness requires every acknowledged message, exact body, FTS entry and expected recipient receipt, and rejects failed, pending or dropped work.

The timed workloads prepare three push recipients per message and exercise the same endpoint-policy rejection. They do not time external push encryption/network delivery, and have no connected Cable subscribers. Actual encryption, provider acceptance/retry and live browser fanout have separate correctness tests. External side effects are at-least-once; a crash after remote acceptance but before the local receipt can cause a duplicate.

Method: Apple M4, 24 GiB RAM; native ARM64 Linux in Docker Desktop; three rounds in rotating Rust/C/Mojo order; 2-second warmups, 8-second samples, 16 keep-alive HTTP/1.1 clients accepting gzip. Servers and their job workers share VM CPUs `0-3`; load generation uses `4-7`. Each application has a 64 MiB response-cache budget. Each retains its own scheduler, cache implementation and compression strategy. This compares completed workloads under a stated configuration, not intrinsic language speed. amd64 emulation is excluded from timing.

The performance runner first checks nine live DOM/SQL/cookie/delivery scenarios. It verifies record-derived Mojo DOM IDs before adapting that known current-Rails security change for comparison with older Rust/C markup. One original C sidebar-initials difference remains explicit. [Reference patches](reference-patches/README.md) record exact bases and the unchanged reference media-golden test limitation.


## Reproduce


Place `once-campfire-rust`, `once-campfire-c`, `once-campfire-verification` and this repository alongside each other. Use the pinned revisions and apply the checked-in local durability patches described in `reference-patches/README.md`. Build all applications with `bench/build.sh` in the toolchain container, then run:

```sh
bash bench/run-durable.sh bench/results/local-durable
```

The runner fails closed on parity, invalid responses, write-audit differences, job failures, queue drops and incomplete drain. Do not set `CAMPFIRE_TEST_NO_AFFINITY` for measurements. `tests/durable_comparison.py` and `tests/durable_inflight.py` separately verify paused-worker and active-lease crash recovery across all three builds. Raw data is local and ignored by Git. Historical stock-port posting measurements are superseded because their background-work and durability contracts differed.


Use a Linux host with eight available logical CPUs for the documented allocation. The displayed numbers describe the measured revisions, not every later documentation/build change. The current source may format differently; KLOC is the recorded value for the measured source.
