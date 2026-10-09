# Local durable comparison patches

These patches extend the exact cloned Rust and C repositories; they are not upstream performance figures. Apply rust-durable.patch at Rust 6dae2fd or c-durable.patch at C 873a51f using git apply, rebuild, and run the Mojo bench/run-durable.sh harness with all repositories as siblings.

The harness explicitly enables CAMPFIRE_DURABLE_JOBS=1, CAMPFIRE_SQLITE_SYNCHRONOUS=FULL, CAMPFIRE_JOB_RECEIPTS=1 and CF_JOB_WORKERS=3. Message changes and outbox admission commit atomically; workers retain failed jobs and per-recipient receipts. Rust awaits delivery completion instead of enqueueing another memory task. This contract covers the five text-message workloads. Arbitrary Rust AdHoc media futures retain their upstream queue semantics.

The benchmark requires exact acknowledged message IDs, bodies, FTS rows and three subscription receipts per message, drains every queue, and rejects drop/failure logs. Crash acceptance pauses workers before 160 posts, kills the full process group, and checks recovery and a second restart. External delivery remains at-least-once; remote acceptance and local receipt cannot form one atomic transaction.

Reference unit checks: Rust formatting and Clippy pass. The full seeded Rust suite and C bench unit suite each retain a video-preview golden-byte mismatch with pinned FFmpeg on ARM64 (11790-byte JPEG versus a 11788-byte golden). The unchanged media path in both ports gives the same mismatch; no golden or test assertion was altered. Text-workload parity, database integrity and forced-crash completion gates pass independently.
