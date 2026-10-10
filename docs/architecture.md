# Architecture

Caddy provides TLS, HTTP/2 and WebSocket proxying. The Mojo parent initializes the
schema and shared event bus, then supervises four HTTP/Cable processes and three
durable-job processes by default. Each process owns a SQLite connection; the
database admits one writer at a time. This is a single-host application.

An HTTP worker uses a nonblocking socket loop. It checks request metadata,
authentication and permissions before routing. Expensive media/network work is
prepared outside the write transaction; permissions are checked again when
admitting prepared changes. Posting atomically commits the message, search index,
unread changes and durable outbox. Rendering/event-size checks happen before
commit so an acknowledged write does not depend on a later fallible rendering step.

Job workers claim eligible rows with an indexed conditional update, retain retries
and record recipient completion. Empty polls do not take the writer lock. Leases
last ten minutes and are renewed from persisted state when five minutes or less
remain. External HTTP effects are at-least-once: a crash between remote acceptance
and recording its receipt can duplicate delivery. Cable is a bounded live event
bus; reconnecting clients resynchronize from persisted history.

| Source | Responsibility |
|---|---|
| `src/main.mojo`, `http.mojo`, `body_stream.mojo`, `file_transfer.mojo` | Process/socket lifecycle, request framing and streamed bodies. |
| `app.mojo`, `controllers.mojo`, `accounts.mojo`, `rooms.mojo`, `ui.mojo` | Routing, identity, account and room workflows. |
| `database.mojo`, `schema.mojo`, `schema_contract.mojo` | SQLite ownership, queries, schema setup/import contract. |
| `parameters.mojo`, `text.mojo`, `crypto.mojo`, `marshal.mojo` | Input values and Rails-compatible text/signing/session formats. |
| `views.mojo`, `richtext.mojo`, `templates/` | View models, sanitization and compiled templates. |
| `storage.mojo`, `media.mojo`, `network.mojo`, `opengraph.mojo` | Disk objects, previews and guarded outbound requests. |
| `cable.mojo`, `pubsub.mojo`, `jobs.mojo`, `webpush.mojo`, `message_actions.mojo` | Realtime events, durable work, push and message operations. |
| `byte_buffer.mojo`, `native_boundary.mojo`, `native/` | Owned binary bytes and the checked FFI/native-library boundary. |
| `tools/manage.py`, `deploy/` | Offline administration and packaged process startup. |

The application policies are Mojo. Small C adapters expose POSIX, SQLite,
OpenSSL, curl, Gumbo, libxml2, libvips and zlib. Raw-pointer/FFI calls are confined
to `native_boundary.mojo`; application modules use owned byte buffers and checked
UTF-8 conversions. See [SAFETY.md](../SAFETY.md). Python generates build inputs,
runs tests and performs offline administration; it is not the HTTP application.

Mojo uses forked synchronous workers; Rust uses an asynchronous Rust stack and C
uses its own native event loops/thread pools. Rust supports the original storage
layout directly; Mojo uses a copying import into `/data`. C explicitly excludes
existing-install/schema upgrades. The timed Rust/C comparison adds local durable
outboxes to align crash guarantees; these are not stock upstream measurements.

Bounded media work can delay a worker's own Cable sockets. A dedicated asynchronous
writer or background media scheduler would require an explicit ownership and
lifecycle design; neither is approximated with ad hoc SQL classification or an
unsafe callback bridge.
