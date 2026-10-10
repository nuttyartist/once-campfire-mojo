# Self-hosting

Campfire in Mojo runs on a single Linux ARM64 or amd64 host with Docker Compose.
Docker Desktop on Apple silicon is supported for local testing. ARM64 has native
local acceptance; native amd64 and hosted CI acceptance remain deferred. The
current version is a pre-release built from source, with no published registry
image or ONCE installation integration. See [release status](releases.md).

## Local setup

From the repository root:

```sh
docker build -f bench/Dockerfile.tools -t campfire-local-tools:verified .
bash tools/build-image.sh campfire-mojo:local
docker compose up -d --no-build --pull never
docker compose ps
```

Open `http://localhost:8080` and create the account and administrator. The first
administrator's contact email appears on the sign-in screen. Local Compose binds
only to loopback. Stop with `docker compose stop`; restart with
`docker compose up -d --no-build --pull never`. Keep the named volume: `down -v` deletes data.

SQLite, files, signing/push keys and certificates live in `/data`. The container
runs as UID 10001. The HTTP app does not run Ruby, Python or a reference server;
Python in the image is for startup key generation and offline administration.

## Public HTTPS

Use the standalone public profile, not a merge with the loopback profile. Point
the domain's DNS at the host and allow inbound TCP 80/443 for Caddy's certificate
validation and service. From the repository root, create a private `.env`:

```dotenv
COMPOSE_PROJECT_NAME=campfire-mojo
CAMPFIRE_IMAGE=campfire-mojo:local
CAMPFIRE_DOMAIN=chat.example.com
VAPID_SUBJECT=mailto:admin@example.com
```

Replace the example domain/contact, then:

```sh
docker compose --env-file .env -f deploy/compose.production.yaml config --quiet
docker compose --env-file .env -f deploy/compose.production.yaml up -d --no-build --pull never
docker compose --env-file .env -f deploy/compose.production.yaml logs --tail 100
```

Caddy maps public 80/443 to container 8080/8443 and obtains certificates. Its
internal Mojo listener stays on loopback. The public profile sets the exact
HTTPS origin so cookies and generated URLs are correct. It does not redirect
plain HTTP automatically; configure a Caddy redirect if needed. The included
automated TLS test uses a local certificate authority, not live ACME issuance.

For commands below on the public profile, set
`export COMPOSE_FILE=deploy/compose.production.yaml`; keep using the same
`COMPOSE_PROJECT_NAME`. The helper reads the repository's `.env`. See the full
[configuration reference](configuration.md) before overriding proxy settings or
resource limits. Keys are generated once and persisted; an environment change
does not replace existing `/data/config.env` values.

## Logs and health

```sh
docker compose ps
docker compose logs --tail 100 campfire
docker compose run --rm --no-deps campfire --version
```

`/up` checks application readiness. Worker exits are supervised; repeated failures
exit the container for Compose to restart. Inspect delivery failures and retained
jobs with `tools/admin.sh check --data /data`. Failed jobs remain for inspection;
they are not silently dropped. Avoid posting configuration files or session
cookies with diagnostic logs.

## Named-volume backups

Stop the application for a consistent database/object/key snapshot. Backups contain
signing keys and should be protected like the live data. Use a new backup name:

```sh
docker compose stop campfire
bash tools/admin.sh backup --data /data --destination /data/backups/before-upgrade
docker compose run --rm --no-deps --entrypoint tar campfire \
  -czf - -C /data/backups before-upgrade > campfire-backup.tar.gz
docker compose up -d --no-build --pull never
```

Copy the archive off the host. The verified application backup includes database,
objects and keys; it does not include Caddy's certificates. Back up `/data/caddy`
separately if retaining certificate state is required. Never replace a live
SQLite database or copy its files while writers are running.

## Restore into a new directory

Keep the old volume as a rollback source. Extract the archive into a private host
directory, then use the packaged verifier to restore into a new directory:

```sh
mkdir -m 700 restore-input restored-site
tar -xzf campfire-backup.tar.gz -C restore-input
docker run --rm --user 0 --entrypoint python3 \
  -v "$PWD/restore-input:/backup:ro" -v "$PWD/restored-site:/restore" \
  campfire-mojo:local /app/tools/manage.py restore \
  --source /backup/before-upgrade --data /restore/site
docker run --rm --user 0 --entrypoint chown \
  -v "$PWD/restored-site:/restore" campfire-mojo:local -R 10001:10001 /restore/site
```

The restore requires an empty/nonexistent target, verifies manifest hashes and
database integrity, and publishes the result atomically. Point a new deployment's
`/data` bind mount at `$PWD/restored-site/site`. Test login, history, attachments
and search before switching traffic. Do not mount the old and restored directories
into two servers serving the same origin at once.

## Updates and rollback

1. Read the new version's changelog and supported schema contract. Record the
   running image ID/version. Tag a local copy as `campfire-mojo:rollback` using
   `docker image tag` so rebuilding `:local` cannot replace that reference.
2. Stop and back up as above. Build the candidate into a different local tag:
   `bash tools/build-image.sh campfire-mojo:candidate`. Run its checks first.
3. Set the Compose image to the candidate (use `CAMPFIRE_IMAGE` for the public
   profile, or a local Compose override). Start with `up -d --no-build --pull never` and
   verify login, history, files, search and jobs.
4. If rollback is required, stop the candidate, restore the pre-upgrade backup
   into a new directory and start the retained old image against it. Do not
   assume an old binary understands a database changed by a newer version.
   Writes since the backup are absent from that rollback snapshot.

No update command automatically pulls, publishes or replaces a remote image.
Current startup performs idempotent schema setup. Future schema changes must
include tested upgrade and rollback instructions before release.

## Import and recovery

[DEPLOYMENT.md](../DEPLOYMENT.md) documents importing a stopped Rails/local-Disk
installation with its original keys, schema rejection and offline recovery.
This is a copying migration into a new `/data` layout. It is not an in-place
replacement for `/rails/storage`, `script/admin/*` or the ONCE image contract.

With the application stopped:

```sh
bash tools/admin.sh check --data /data
bash tools/admin.sh retry-jobs --data /data
bash tools/admin.sh gc-files --data /data
```

`retry-jobs` retries retained failures; receivers must tolerate at-least-once
delivery. `gc-files` removes unreferenced files left by interrupted preparation.
The shared database lock rejects destructive offline work while the app runs.

## Troubleshooting

| Symptom | Check |
|---|---|
| Port already in use | Stop the conflicting service or change both local port mapping and `PUBLIC_ORIGIN`. |
| Sign-in/write rejected after proxy change | Exact browser origin, HTTPS metadata and private/trusted proxy configuration. |
| Permission denied under `/data` | Bind mount ownership for UID 10001; keep key file mode 0600. |
| Push unavailable | Persisted VAPID pair/subject, browser HTTPS permission, outbound network and retry logs. |
| Slow large upload or missing preview | Disk space for spool/object, configured limits, supported codecs and decoder logs. Unpreviewable files remain downloadable. |
| amd64 preview fails on an Apple host | Known Rosetta helper allocation limitation under the retained 2 GiB safety bound; use native ARM64. Emulation is not native amd64 acceptance. |
| Import rejected | Supported schema, stopped source, original keys, local Disk service, object hashes and orphan policy. Do not edit the source to bypass validation. |
