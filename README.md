# Campfire in Mojo

A standalone Mojo implementation of [Campfire](https://github.com/basecamp/once-campfire),
the self-hosted chat application from Basecamp. It provides rooms with access
controls, direct messages, rich text and mentions, file attachments and previews,
search, live updates, Web Push notifications and bot integrations.

The supported deployment is a single Linux machine with SQLite and local Disk
storage. Existing stock Rails installations at the documented schema can be
copied into a new Mojo deployment while retaining passwords, sessions, objects
and signing keys. See [compatibility and differences](PORT_STATUS.md).

This is an independent **0.1.0-dev pre-release**. No repository, release or image
has been published by this project. Native amd64/hosted CI acceptance and a
public maintenance/security contact remain deferred; see [release status](docs/releases.md).
The current container also has an unresolved [dependency security gate](docs/security-review.md).

## Run locally

From this checkout, with Docker Compose installed:

```sh
docker build -f bench/Dockerfile.tools -t campfire-local-tools:verified .
bash tools/build-image.sh campfire-mojo:local
docker compose up -d --no-build --pull never
```

Open `http://localhost:8080` and create the account and administrator. Data and
keys persist in the Compose volume. Stop with `docker compose stop`; do not use
`down -v` unless you intend to delete the data.

[Self-hosting and HTTPS](docs/self-hosting.md) ·
[Configuration](docs/configuration.md) ·
[Rails import and recovery](DEPLOYMENT.md) ·
[Development and tests](docs/development.md)

## Implementation

Routing, authentication, permissions, SQL, rendering, Action Cable, storage policy
and durable jobs are Mojo. Caddy fronts a supervised group of Mojo HTTP/Cable and
job processes. Small C adapters expose established native libraries and POSIX;
the HTTP server does not run Python, Ruby, or a Rust/C Campfire server.

Binary data uses owned byte buffers with explicit UTF-8 decoding. Raw-pointer/FFI
operations are confined to one checked native boundary. Messages, search/unread
changes and queued work commit together using SQLite FULL-WAL durability.
Recipient receipts and retries survive process failure; external delivery is
at-least-once. Read the [architecture](docs/architecture.md),
[safety contract](SAFETY.md) and [tested scope](PORT_STATUS.md) for details.

## Local performance

The latest measured comparison uses the same machine, four server CPUs, gzip,
bounded caches, FULL durability and exact background-job completion. Rust and C
use explicitly documented local durability patches. These are completed-work
measurements, not stock upstream results or intrinsic language-speed claims.

| Workload (completed requests/sec) | Rust* | C* | Mojo |
|---|---:|---:|---:|
| Room page | 44,403 | 55,590 | 55,743 |
| Messages page | 41,337 | 55,509 | 59,515 |
| Sidebar | 50,500 | 59,726 | 62,094 |
| Search | 49,577 | 62,785 | 59,204 |
| Post a message | 1,180 | 382 | 1,090 |
| Backend KLOC at measured revision | 30.9 | 94.8 | 8.0 |

Measured on Apple M4/24 GiB in native ARM64 Linux, 16 clients and three rotating
rounds. The posting audit checked 256,162 messages and 768,486 recipient completions
with no missing/dropped jobs. Timed recipients exercise endpoint-policy rejection;
external push transport and connected Cable subscribers are tested separately.
Measured Mojo revision: `3b7440dc3f84`. See [full method, every round and reproduction](bench/README.md).

## Contributing and security

[CONTRIBUTING.md](CONTRIBUTING.md) describes code, test and provenance requirements.
Use the independent Rails fixtures and packaged browser/migration gates before
proposing compatibility changes. [SECURITY.md](SECURITY.md) explains the trust
model and the current reporting/support status.

## License

The application is MIT-licensed; retain [MIT-LICENSE](MIT-LICENSE).
Frontend assets, vendored native libraries and the Mojo runtime distribution have
their own notices. See [third-party notices](THIRD_PARTY_NOTICES.md),
[source provenance](PROVENANCE.md) and the included `licenses/` directory.
