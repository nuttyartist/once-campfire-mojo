# Configuration

The packaged server reads environment variables at startup. Restart after changes.
Compose substitutes variables from the shell or `.env`; only variables listed in
the service's `environment` block reach the container. Use a Compose override for
advanced settings. Never commit real credentials. See [self-hosting](self-hosting.md).

| Setting | Packaged default | Purpose |
|---|---|---|
| `PUBLIC_ORIGIN` | `http://localhost:8080` | Exact browser-facing origin, including a nonstandard port; controls URLs and secure cookies. |
| `CAMPFIRE_SITE` | `http://:8080` | Caddy site address. A public hostname enables certificate issuance. |
| `VAPID_SUBJECT` | `mailto:admin@example.invalid` | Set a real contact URI before initializing a public deployment. Persisted with the keys. |
| `SECRET_KEY_BASE` | Generated once | Optional initial signing secret, at least 32 bytes. Preserve when importing Rails. |
| `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` | Generated once | Optional initial URL-safe Base64 P-256 pair; supply both or neither. |
| `MOJO_WORKERS` | `4` | HTTP/Cable processes, 1–32. Synchronous media can occupy one process. |
| `JOB_CONCURRENCY` | `3` | Durable background processes, 1–32. |
| `CAMPFIRE_RESPONSE_CACHE_MB` | `64` | Total response-cache budget divided among HTTP workers; 0 disables, maximum 1024 MiB. |
| `MULTIPART_BYTESIZE_LIMIT` | `10737418240` | Decoded multipart/direct-upload limit in bytes (10 GiB). Spools use disk. |
| `CAMPFIRE_SQLITE_SYNCHRONOUS` | `FULL` | WAL durability. `NORMAL` is an explicit weaker opt-in, excluded from fair results. |
| `CAMPFIRE_DATA` | `/data` | Key/config directory for the packaged entrypoint. |
| `DATABASE_PATH` | `/data/production.sqlite3` | Application database; one supervised server owns each database. |
| `STORAGE_PATH` | `/data/files` | Active Storage Disk objects. |
| `PUBLIC_PATH` | `/app/public` | Packaged static assets. |
| `BIND_ADDRESS`, `PORT` | `127.0.0.1`, `3000` | Internal HTTP listener behind Caddy; application port 1024–65535. |
| `TRUSTED_PROXY_IP` | `127.0.0.1` | Only this socket peer may supply forwarded client IPs. Do not expose the internal listener. |
| `TMPDIR` | `/tmp` | Streamed upload spools and bounded media-helper temporary files. |
| `XDG_DATA_HOME`, `XDG_CONFIG_HOME` | `/data/caddy` | Persisted certificates and Caddy state. |

On first boot, keys and the initial VAPID subject are written to
`/data/config.env` with mode 0600. That persisted file wins over subsequent
environment changes. Changing `.env` alone does not rotate keys or update a
previously initialized VAPID subject. With the app stopped, an operator can edit
the persisted configuration while retaining keys and its permissions. Back it up
first. Unplanned key rotation invalidates sessions, signed URLs and subscriptions.

The supplied Compose profiles allocate four CPUs, 2 GiB memory and 160 PIDs.
Adjust those service limits for the host and workload. Keep storage local to a
single machine; network filesystems and shared multi-host writers are unsupported.
Reserve space for the upload spool, the stored object and backups.

`CAMPFIRE_JOBS_PAUSED`, `CAMPFIRE_JOB_RECEIPTS`, `MOJO_BENCH_DIAGNOSTICS` and
`MOJO_AUDIT_PATH` are acceptance/diagnostic settings, not normal deployment
requirements. Receipt/audit retention grows without automatic pruning. Do not
enable the benchmark diagnostics endpoint on a public deployment.

See [compatibility limits](../PORT_STATUS.md) for message, multipart, decoder,
connection and event-size limits. Optional Rails telemetry, remote storage,
plugins, `TLS_DOMAIN`/`DISABLE_SSL` aliases and ONCE administration hooks are not
part of this deployment interface.
