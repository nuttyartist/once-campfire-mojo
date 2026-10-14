# Independent upstream verification

`bash tools/check-upstream.sh` runs the public
[Basecamp verification harness](https://github.com/basecamp/once-campfire-verification)
at the immutable revision in [test-pins.env](../tools/test-pins.env). Run
`tools/bootstrap-tests.sh` and build the production image first, as described in
[development](development.md). The gate requires Docker, Git, Ruby, Python 3.11+,
Node.js 22.18+ and npm. It downloads the lockfile's Playwright and Chromium.

```sh
bash tools/build-image.sh campfire-mojo:ci
bash tools/check-upstream.sh
# Optional: select an already built local production image.
APPLICATION_IMAGE=campfire-mojo:candidate bash tools/check-upstream.sh
```

The original verification checkout stays untouched. A disposable checkout receives
[runner.patch](../tools/upstream/runner.patch), which adds `--apps mojo` and calls
the [Mojo deployment adapter](../tools/upstream/mojo.rb). The patch only registers
the application, selects its entrypoint/configuration, prepares writable disposable
storage on a Docker volume, preserves failure logs and adds job-completion validation. The upstream assertions, contract SQL,
fixture contents, browser flows, load generator and acknowledged-write auditor are
not replaced or edited. Every other tracked upstream file is compared byte for byte
against the pinned commit before and after execution; the runner must match exactly
the reviewed patch. Negative tests deliberately alter these files to check rejection.

The gate runs:

- The unchanged browser smoke suite against a fresh packaged production server,
  including setup, live messaging, editing, search, settings, bots, session transfer,
  joining and direct pings. The separate Mojo browser suite retains its extra tests.
- The unchanged sidebar, editor-preservation and autocomplete controller regressions
  against the actual digested JavaScript files served by Mojo.
- Upstream `bin/check`: Rust formatting, Clippy and unit tests; Ruby contract,
  benchmark, sample, acknowledged-write and template-code tests; JavaScript syntax.
- Upstream `bin/benchmark --apps mojo` for all eight routes: room, message page,
  sidebar, search, avatar, CSS, health and message creation. Contracts are generated
  by upstream Ruby directly, including real image decoding and independent SQL.
- The upstream mixed-read/write profile with its paced writer. Both profiles use
  two rounds, 16 concurrent readers and two-second measurements, plus the upstream
  warmups. These are correctness gates, not a new cross-language performance table.

The adapter requires SQLite `FULL`, active job workers and durable completion
receipts. After every round it requires exact agreement between acknowledged
messages, persisted messages, completed jobs and the expected recipient/message
pairs; pending, failed, retried, missing or extra work fails the gate. Notification
endpoints use upstream's local policy-rejection fixtures. This does not claim
external push-provider delivery; Mojo's independent encrypted push-receiver and
fault-recovery tests remain necessary. Shutdown must complete successfully and the
server log must not report request, worker or job failures.

## Known intermittent upstream browser failure

At the pinned revision, `browser/smoke.mjs` waits for the third message to appear
in the receiving tab, then immediately counts confirmed messages in both tabs.
The sending tab can still have two confirmed messages and the third optimistic
message awaiting its HTTP/WebSocket update. This produces the upstream
"duplicate or missing" failure even when both tabs subsequently contain exactly
three messages. Local runs have both passed and failed; a diagnostic snapshot
captured the sending tab's pending third message at the failing count.

The upstream browser file and all its assertions remain unchanged. There is no
retry, skip, timing workaround or relaxed assertion in this adapter. A browser
failure keeps the overall gate failed. The wrapper still runs the independent
HTTP and mixed-write checks and retains their results, so the intermittent
browser failure does not hide other failures. A green local browser run alone
does not resolve this known race.

CI runs this gate on both native Linux architectures in the application matrix,
without `continue-on-error`. It retains integrity manifests, application and harness
logs and result summaries even on failure. The local command only creates disposable
containers and volumes, plus checkouts and ignored evidence under `build/upstream/`; it does
not use the user's application data or push images/source. The benchmark process
uses the host Docker socket and host networking inside its trusted Linux tool
container. Host and container paths must match; the wrapper sets these mounts.
Live SQLite databases use a dedicated Linux Docker volume shared by the runner
and application containers. They must not live on Docker Desktop's macOS shared
filesystem: local stress runs there produced SQLite corruption and failed requests.
The volume is removed after the run; failure logs and results stay on the host.
The Linux client image selects `C.UTF-8` so Ruby validates UTF-8 HTML consistently.
At least two Docker CPUs are required. CPU affinity is derived from the available
set; small CI machines are not suitable for published speed comparisons.

Changing the verification pin requires reviewing the deployment patch and rerunning
both the integrity regressions and complete gate. A successful run establishes the
coverage above. It does not establish complete Rails parity, native amd64 acceptance
from emulation, dependency security clearance or an active maintenance policy.
