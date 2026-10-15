# Releases and dependency maintenance

`VERSION` is the application version; currently `0.1.0-dev` is unreleased.
There is no official support commitment, public registry image or active private
security-reporting channel. This repository publishes the source of an independent
port for review. It is not a Basecamp release. The [hosted workflow](https://github.com/nuttyartist/once-campfire-mojo/actions/workflows/ci.yml)
runs native ARM64 and amd64 checks; a workflow configuration alone does not establish
platform acceptance. Setting a public maintenance/security contact remains deferred.

The current binary candidate also has an unresolved [dependency release gate](security-review.md).
The local package rebuild did not resolve the distribution advisories. Source
review can proceed with this disclosed status; a supported image release cannot
be described as security-cleared.

## Local candidate

Start from a clean commit and run the standalone, independent upstream, browser, migration and package
gates in [development](development.md). Build with `tools/build-image.sh` so the
image records the version, full Git revision and chosen `SOURCE_URL` (default
`local`). `docker run --rm IMAGE --version` prints the binary's identity without
starting the app, creating a database or generating keys.

```sh
bash tools/build-image.sh campfire-mojo:candidate
APPLICATION_IMAGE=campfire-mojo:candidate bash tools/check-package.sh
APPLICATION_IMAGE=campfire-mojo:candidate bash tools/check-security.sh
bash tools/release-local.sh campfire-mojo:candidate release/candidate
```

The last command exports the existing local image, sanitized evidence, source
archive, checksums and image metadata. It does not push, create a tag/release,
contact GitHub, or upload anything. Protect release directories as local build
artifacts; they are ignored by Git. Review the package before sharing it.

## Before a supported release

- Replace the development suffix and update `CHANGELOG.md` with user-visible
  changes, tested schema upgrades/rollback and platform limits.
- Require native ARM64 and native amd64 acceptance for the exact source commit.
  Emulation and workflow syntax checks must not be relabelled as native CI.
- Review the dependency scan, notices, source/asset hashes and build identity.
  Preserve the Mojo distribution license and third-party notices with its runtime
  libraries; the application MIT license does not relicense those dependencies.
- Assign a maintainer and enable the private reporting route described in
  [SECURITY.md](../SECURITY.md). These organizational steps are not completed by
  a local script.
- Independently authorize repository/image publication. The supplied workflows
  test and retain build evidence, but do not publish registry images or releases.
  When a registry release is later introduced, use digest-pinned multi-architecture
  manifests, provenance attestations and signing; verify those before moving tags.

## Dependency updates

`tools/security-pins.env` pins scanner images. `tools/check-security.sh` runs
local secret/history and image-vulnerability scans. Scanners may download public
rules/advisory databases; application source and image layers are not uploaded.
The scheduled advisory workflow is prepared but inactive until this repository
is published and workflows are enabled. Record its database date with results.
Do not silently ignore findings: document any reviewed false positive at the
narrowest path/rule, with a reason. Current known test-key exceptions are explicit.

Mojo is pinned by version in `requirements.txt` and `bench/Dockerfile.tools`;
the Rust base image is pinned by digest. Debian packages receive distribution
updates and are not snapshot-pinned. Rebuild with current package indexes for a
release, scan the actual final image, and preserve its package inventory and
digest. A source revision alone does not promise byte-identical builds across
package-update dates.

To update vendored SQLite/Gumbo/QR code, record source revision, content hashes
and notices, then run the full suite and native sanitizer harness. To update
frontend dependencies, follow [frontend.md](frontend.md) and review the independent
Rails corpus/browser regressions. Update runtime notices from the same official
Mojo release as the installed compiler, rather than treating wheel metadata as
an application license.
