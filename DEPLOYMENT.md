# Data migration and recovery

For a fresh installation, public HTTPS, named-volume backup commands and image
updates, start with [self-hosting](docs/self-hosting.md). See
[configuration](docs/configuration.md) for settings/defaults and
[release status](docs/releases.md) for platform acceptance and support scope.

Build on ARM64 or amd64 Linux (Docker Desktop on Apple silicon is supported):

```sh
docker build -f bench/Dockerfile.tools -t campfire-local-tools:verified .
bash tools/build-image.sh campfire-mojo:local
docker compose up -d --no-build
```

Open `http://localhost:8080`. The first visit creates the account and administrator. The named `campfire` volume contains the SQLite database, Disk files, signing/VAPID keys, and Caddy data. Do not delete that volume to update the image. Keep live SQLite files on a Linux filesystem or Docker named volume; Docker Desktop macOS host bind mounts are unsupported for the live database because stress tests observed corruption there. Compose binds published ports to loopback, limits the container to four CPUs and 2 GiB, and checks the application health endpoint.

`SECRET_KEY_BASE` and the two VAPID keys are generated once into `/data/config.env` with mode 0600. Back up that file with the database and files. Losing or changing these keys invalidates sessions, signed URLs and existing push registrations. `VAPID_SUBJECT` should be a contact address for an actual deployment.

For HTTPS, set `PUBLIC_ORIGIN` to the browser-facing origin and `CAMPFIRE_SITE` to the Caddy site address. Caddy handles TLS, HTTP/2, and WebSocket upgrades; Mojo listens on loopback behind it. A public deployment requires the corresponding port mappings, DNS and reachable certificate-validation ports. The supplied local Compose configuration does not publish a service to the Internet. Only Caddy's loopback peer is trusted to supply the client address; forwarded host/protocol headers do not determine signing or redirects.

## Copy an existing installation

Stop the original application and its job workers after queued work drains. Keep its data as your rollback source. The importer makes a read-only file copy of the source database and committed WAL into a private snapshot, then opens SQLite only on that snapshot. It checks table/integrity/file checksums, and copies into a new destination. It never updates the original in place.

Supply a private key file containing the original `SECRET_KEY_BASE`, `VAPID_PRIVATE_KEY`, `VAPID_PUBLIC_KEY`, and optionally `VAPID_SUBJECT` as `KEY=value` lines. This file is parsed as data, not executed. Existing push subscriptions require both original VAPID keys. Obtain these values from the existing installation's configuration; never commit them.

```sh
python3 tools/manage.py import-rails \
  --source /path/to/original/storage/db/production.sqlite3 \
  --files /path/to/original/storage/files \
  --config-env /path/to/private-original-keys.env \
  --data /path/to/new-mojo-data
```

This supports the original `local` Active Storage Disk service and the current Rails `b52b244` schema, including the shared pre-counter layout used by the independent Rails seed. All 16 original table/column contracts are validated. The importer upgrades room counters and installs the original count triggers/indexes. Older incompatible or future schemas are rejected before accepting the import; upgrade older sources with Rails first. Remote storage objects must first be exported into a consistent local Disk installation. Missing referenced files, changed databases, corrupt checksums, symlinks, unsupported schemas, existing foreign-key violations, and existing destinations stop the import. If the original installation intentionally retains orphaned records (as the shared test fixture does), `--allow-existing-orphans` preserves those rows and records each existing violation in `import.json`; it does not fabricate missing records or repair corrupt files. Uncompleted, unattached direct-upload rows may lack a file.

Mount the resulting directory at `/data` with ownership allowing container UID 10001 access. Verify login, room history, attachments, search, and bot integrations before changing the browser-facing origin. Keep the original installation stopped while the copy is active; this is not a replication or dual-writer setup. Rollback means stopping Mojo and restoring the original deployment; subsequent Mojo writes will not appear in that original copy.

## Backup, restore and recovery

Run offline operations with the application stopped so the database, objects and keys form one snapshot:

```sh
python3 tools/manage.py backup --data /path/to/mojo-data --destination /path/to/new-backup
python3 tools/manage.py restore --source /path/to/backup --data /path/to/empty-restored-data
python3 tools/manage.py check --data /path/to/mojo-data
python3 tools/manage.py retry-jobs --data /path/to/mojo-data
python3 tools/manage.py gc-files --data /path/to/mojo-data
```

Backups include a SHA-256 manifest, database, Disk files, keys and any accepted-orphan import provenance. Files and parent directories are synced; restore verifies a temporary destination before atomically renaming it. Restore verifies the manifest and requires an empty destination. The application and offline tools share an exclusive lock for destructive offline operations. Check the container logs for background delivery errors and inspect queued/failed job counts with `check`; `retry-jobs` makes failed deliveries eligible again.

Committed file-deletion intents also survive termination and retry failed unlinks. `gc-files`, with the application stopped, removes orphaned objects from interrupted pre-commit preparation while preserving every referenced key.

Acknowledged messages and queued work survive process termination. Successful recipient deliveries have receipts, but HTTP side effects cannot be atomic with the local database: webhook consumers should tolerate retries. Worker exits are supervised and repeated crashes terminate the container for Compose to restart.

Multipart and signed direct-upload bodies default to 10 GiB (`MULTIPART_BYTESIZE_LIMIT`) and spool to anonymous files under `TMPDIR` (default `/tmp`). Allocate disk space for a request spool and its stored object; cleanup closes/unlinks aborted spools. Multipart text is limited to 16 MiB, 4,096 parts and 128 files. Other requests retain their bounded buffered-body policy. Downloads use 64 KiB chunks; connection buffers are bounded to 128 MiB per HTTP worker, with 1,024 connections per worker, bounded Cable queues, a 30-second idle limit and a 30-minute streamed-upload deadline. Media decoding is restricted to bounded dimensions/pixel counts and time-limited subprocesses. These limits and the compatibility notes in `PORT_STATUS.md` apply when evaluating an existing installation.

## Durability and architecture acceptance

Mojo now defaults to SQLite `synchronous=FULL` in WAL mode. `CAMPFIRE_SQLITE_SYNCHRONOUS=NORMAL` is an explicit weaker opt-in and is not used by the durable comparison. FULL requests a WAL sync before commit returns; hardware/virtualization must honor filesystem sync for power-loss guarantees. Tests kill application processes, not the user's Mac or Docker VM. External HTTP effects cannot be atomically committed with SQLite and may repeat after a crash; local recipient receipts prevent redoing already recorded work.

`CAMPFIRE_JOBS_PAUSED=1` starts workers paused while retaining queued work durably; restart without it to resume. This supports controlled recovery acceptance. `CAMPFIRE_JOB_RECEIPTS=1` retains additional completion receipts for comparison/audit; it is not required for production recovery and grows audit tables.

To build the second architecture locally:

```sh
docker build --platform linux/amd64 -f bench/Dockerfile.tools -t campfire-local-tools:amd64 .
docker build --platform linux/amd64 --build-arg TOOLCHAIN_IMAGE=campfire-local-tools:amd64 -t campfire-mojo:amd64 .
```

The amd64 image was booted under local emulation and exercised with the browser smoke suite. Native ARM64 alone supplies the comparison's performance numbers. `tests/browser_push.mjs` uses a disposable Chrome profile, grants permission only for the local acceptance app, verifies a real provider subscription/delivery, unsubscribes it and removes the profile. Set `PLAYWRIGHT_MODULE`, `CAMPFIRE_PUSH_TEST_BASE` and `CAMPFIRE_PUSH_TEST_OUTPUT` for your environment.
