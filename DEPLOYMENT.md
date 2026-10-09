# Local deployment and data migration

Build on ARM64 Linux (Docker Desktop on Apple silicon is supported):

```sh
docker build -f bench/Dockerfile.tools -t campfire-local-tools:latest .
docker compose build
docker compose up -d
```

Open `http://localhost:8080`. The first visit creates the account and administrator. The named `campfire` volume contains the SQLite database, Disk files, signing/VAPID keys, and Caddy data. Do not delete that volume to update the image. Compose binds published ports to loopback, limits the container to four CPUs and 2 GiB, and checks the application health endpoint.

`SECRET_KEY_BASE` and the two VAPID keys are generated once into `/data/config.env` with mode 0600. Back up that file with the database and files. Losing or changing these keys invalidates sessions, signed URLs and existing push registrations. `VAPID_SUBJECT` should be a contact address for an actual deployment.

For HTTPS, set `PUBLIC_ORIGIN` to the browser-facing origin and `CAMPFIRE_SITE` to the Caddy site address. Caddy handles TLS, HTTP/2, and WebSocket upgrades; Mojo listens on loopback behind it. A public deployment requires the corresponding port mappings, DNS and reachable certificate-validation ports. The supplied local Compose configuration does not publish a service to the Internet. Only Caddy's loopback peer is trusted to supply the client address; forwarded host/protocol headers do not determine signing or redirects.

## Copy an existing installation

Stop the original application and its job workers after queued work drains. Keep its data as your rollback source. The importer reads the source database in read-only mode, includes committed WAL data, checks table/integrity/file checksums, and copies into a new destination. It never updates the original in place.

Supply a private key file containing the original `SECRET_KEY_BASE`, `VAPID_PRIVATE_KEY`, `VAPID_PUBLIC_KEY`, and optionally `VAPID_SUBJECT` as `KEY=value` lines. This file is parsed as data, not executed. Existing push subscriptions require both original VAPID keys. Obtain these values from the existing installation's configuration; never commit them.

```sh
python3 tools/manage.py import-rails \
  --source /path/to/original/storage/db/production.sqlite3 \
  --files /path/to/original/storage/files \
  --config-env /path/to/private-original-keys.env \
  --data /path/to/new-mojo-data
```

This supports the original `local` Active Storage Disk service and current shared Campfire schema. Remote storage objects must first be exported into a consistent local Disk installation. Missing referenced files, changed databases, corrupt checksums, symlinks, unsupported schemas, existing foreign-key violations, and existing destinations stop the import. If the original installation intentionally retains orphaned records (as the shared test fixture does), `--allow-existing-orphans` preserves those rows and records each existing violation in `import.json`; it does not fabricate missing records or repair corrupt files. Uncompleted, unattached direct-upload rows may lack a file.

Mount the resulting directory at `/data` with ownership allowing container UID 10001 access. Verify login, room history, attachments, search, and bot integrations before changing the browser-facing origin. Keep the original installation stopped while the copy is active; this is not a replication or dual-writer setup. Rollback means stopping Mojo and restoring the original deployment; subsequent Mojo writes will not appear in that original copy.

## Backup, restore and recovery

Run offline operations with the application stopped so the database, objects and keys form one snapshot:

```sh
python3 tools/manage.py backup --data /path/to/mojo-data --destination /path/to/new-backup
python3 tools/manage.py restore --source /path/to/backup --data /path/to/empty-restored-data
python3 tools/manage.py check --data /path/to/mojo-data
python3 tools/manage.py retry-jobs --data /path/to/mojo-data
```

Backups include a SHA-256 manifest, database, Disk files and keys. Restore verifies the manifest and requires an empty destination. The application and offline tools share an exclusive lock for destructive offline operations. Check the container logs for background delivery errors and inspect queued/failed job counts with `check`; `retry-jobs` makes failed deliveries eligible again.

Acknowledged messages and queued work survive process termination. Successful recipient deliveries have receipts, but HTTP side effects cannot be atomic with the local database: webhook consumers should tolerate retries. Worker exits are supervised and repeated crashes terminate the container for Compose to restart.

Current size limits are 64 MiB per uploaded request, 64 KiB chunks per downloaded file, 128 MiB of connection buffers per HTTP worker, 1,024 connections per worker, bounded Cable queues, and 30-second incomplete-request/idle timeouts. Media decoding is restricted to bounded dimensions/pixel counts and time-limited subprocesses. These limits and the compatibility notes in `PORT_STATUS.md` apply when evaluating an existing installation.
