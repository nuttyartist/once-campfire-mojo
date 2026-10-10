# Dependency review status

The 2026-10-10 local publication pass added a failing dependency gate rather than
treating application tests as a security certification. A fresh Debian Trixie
runtime image, rebuilt after refreshing the official base and package indexes,
still produces **282 HIGH/CRITICAL package findings covering 89 distinct CVEs**
in Trivy 0.75.0: 279 HIGH and 3 CRITICAL package findings. The scanner lists no
fixed Trixie package version for those entries. Repeated findings across binary
packages from the same source are not counted as separate CVEs.

This is a package-presence scan, not proof that every reported path is reachable
through Campfire. Conversely, process isolation and passing malformed-input tests
do not establish that the media/XML dependency findings are harmless. The current
image has **not passed the dependency release gate**. There is no blanket CVE
ignore file, `--ignore-unfixed`, or allow-failure security job.

The three scanner-critical entries include two OpenEXR issues and one libxml2
issue. Debian's tracker records the current Trixie packages as vulnerable for
[CVE-2026-42216](https://security-tracker.debian.org/tracker/CVE-2026-42216),
[CVE-2026-42217](https://security-tracker.debian.org/tracker/CVE-2026-42217) and
[CVE-2026-6653](https://security-tracker.debian.org/tracker/CVE-2026-6653).
Debian classifies the last as a minor/no-DSA issue, illustrating that scanner
severity is not a deployment-specific exploitability assessment. Fixed upstream
or unstable-distribution versions do not mean a fixed Trixie package is available.

Before a supported binary release, use a maintained dependency set with fixes,
or document a narrow, evidence-backed applicability assessment for each finding.
Changing the distribution or maintaining custom native-library backports requires
another full compatibility and packaging pass. Do not mix unstable packages into
the stable image merely to make a version scanner green, remove preview features,
or weaken parser/process limits to get a passing result.

The known nested frontend package inventory reports no HIGH/CRITICAL advisories
at this scan date. This inventory and the OS package scanner do not automatically
discover every statically linked or SDK component; source provenance, upstream
notices and native-boundary review remain separate requirements.

Source and full local Git history scans pass after reviewed generic-key exceptions
for independent public Rails vectors, a disposable attachment filename, SQLite
identifier names and a Lexical selection expression. The exceptions are scoped
in `.gitleaks.toml`; current and historical crypto/storage fixture hashes are
verified before the security scan. No test directory or credential-rule family
is globally excluded. A passing secret scan is evidence, not a guarantee that
no sensitive information exists.

Run `APPLICATION_IMAGE=IMAGE bash tools/check-security.sh` for current redacted
reports under `build/security`. The gate downloads public advisory data but does
not upload application source or image layers. Its nonzero result is expected
until the image findings are resolved or individually justified.
