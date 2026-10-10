# Changelog

## 0.1.0-dev — unreleased

- Stock Campfire rooms, messages, accounts, bots, rich text, files, WebSockets and
  Web Push implemented in Mojo with a checked native-library boundary.
- FULL-WAL transactional outbox, retry/receipt recovery and durable file cleanup.
- Schema-checked copying import from the documented Rails/local-Disk layouts,
  preserved session/signing keys, offline backup and verified restore.
- Streamed uploads/downloads, bounded media processing, Docker/Caddy deployment.
- Independent Rails vectors, binary/crypto regressions, browser/TLS/migration
  gates and native adapter sanitizer/fuzz coverage.
- Publication notices, frontend provenance, build identity, release tooling and
  maintainer documentation. No public release or registry image has been made.

Historical local measurements are in `bench/acceptance/`. They are experiments,
not release versions. Future release notes must describe upgrade steps, supported
schema/platform changes and security fixes without claiming unrun acceptance.
