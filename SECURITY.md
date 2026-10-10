# Security

The current image has unresolved distribution advisories and has not passed the
dependency release gate. See the [dated dependency review](docs/security-review.md)
and rerun the local scan before any binary release.

This is an independent pre-release Campfire port. There is no supported public
release or active private reporting address yet; assigning a maintainer and
activating a reporting channel are deferred. Basecamp's vulnerability program
must not be assumed to cover this repository.

Before a public supported release, the repository owner must enable GitHub
private vulnerability reporting (Security → Advisories → Report a vulnerability)
or publish a monitored private address here, and document supported versions.
Do not post exploit details, credentials or user data in a public issue. Ordinary
non-sensitive bug reports should include the version/revision, platform and a
minimal reproduction using disposable data.

## Trust model

Campfire is self-hosted and single-tenant. Administrators operate the deployment
and can configure bot webhooks to internal services. Member-triggered unfurls and
push endpoints instead use destination restrictions and address validation.
Authentication, room authorization, request metadata/origin checks and bounded
resource use apply to non-administrators. The internal Mojo listener trusts only
the configured proxy peer and must remain private.

Report non-administrator access to another room's data, stored-script execution,
unsafe network destinations, credential exposure, memory corruption, or resource
consumption out of proportion to input. A safe reproduction and affected revision
are more useful than testing against another person's server.

[SAFETY.md](SAFETY.md) describes byte ownership and the trusted native boundary.
[PORT_STATUS.md](PORT_STATUS.md) describes compatibility and delivery guarantees.
Tests and sanitizer results are evidence, not a proof that all vulnerabilities
have been eliminated. See [release gates](docs/releases.md) for pending native
platform acceptance and dependency maintenance.
