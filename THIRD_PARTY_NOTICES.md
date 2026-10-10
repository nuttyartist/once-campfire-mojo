# Third-party notices

The Campfire application and derived original/Rust templates are covered by
`MIT-LICENSE`. This does not replace the licenses of bundled dependencies.
`licenses/manifest.json` records the source, version and SHA-256 of every retained
notice. The same files are installed at `/app/licenses` in the container, alongside
this document and `/app/MIT-LICENSE`.

## Frontend

Original Campfire and Rails/Hotwire code retains its MIT notices. Lexxy retains
Jorge Manrubia's MIT notice. Lexical (including its bundled modules), Prism,
Marked, DOMPurify, regenerator-runtime, highlight.js and SparkMD5 retain their
package notices under `licenses/frontend/`. DOMPurify versions differ between
the Lexxy and legacy Trix bundles; both are recorded. The component names are an
attribution inventory, not a claim that every package in an upstream SDK executes
at runtime. Source/export hashes and overrides are in `assets/source-lock.json`;
the upstream gem inventory is in `assets/upstream-manifest.md`.

## Native code and system packages

SQLite is public domain. Gumbo/Nokogiri and the QR generator retain their notices
under `vendor/` and `licenses/native/`. The final image's distribution packages
(Caddy, OpenSSL, curl, libvips, libxml2, zlib, FFmpeg, Poppler and dependencies)
retain Debian copyright/license files under `/usr/share/doc` and
`/usr/share/common-licenses`. Do not remove those files when repackaging an image.
Record actual package versions and the image digest with release evidence.

## Mojo compiler and runtime

The application uses Mojo 1.1.0 and copies three runtime libraries from the official
`mojo-compiler` distribution: `libKGENCompilerRTShared.so`,
`libMSupportGlobals.so` and `libAsyncRTRuntimeGlobals.so`. They are unmodified and
are not relicensed under the application's MIT license. The installed wheel
metadata declares `LicenseRef-MAX-Platform-Software-License`; the matching official
source release contains both the Apache-2.0-with-LLVM-exceptions source license
and Modular's distribution terms and third-party notices. All three are retained
verbatim in `licenses/mojo/` with their pinned source hashes.

The official source revision is `c6fa49f712fe15c99d0461ad2baaf2a15cbc58ce`
(`mojo/v1.1.0`). The public source license and wheel metadata describe different
distribution surfaces; this project does not silently resolve that distinction
by labelling prebuilt runtimes MIT. Preserve the supplied terms/notices when
building locally. Before distributing a supported binary image, confirm the
component-specific redistribution terms for the chosen runtime distribution.
Source publication contains no compiler or runtime binary. No such binary
publication has been made here.
