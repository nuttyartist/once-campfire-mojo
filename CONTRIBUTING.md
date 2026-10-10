# Contributing and upstream review

Use the build/bootstrap/standalone and packaged gates in `README.md`. The default CI targets native Ubuntu ARM64 and amd64. Keep fixture credentials, databases, output logs, binaries and benchmark receipts out of commits. `tools/test-pins.env` names the immutable external references.

For an original behavior change, add an independent regression before changing the port. Regenerate rich-text expectations with `tools/regenerate-corpus.sh` against the pinned original image, never from Mojo output. Regenerate `tools/schema_contract.json` and `src/schema_contract.mojo` together with `tools/update_schema_contract.py`. Preserve explicit schema rejection and test both upgrade and current-layout paths. Do not turn reference mismatches into silent exclusions.

`make` regenerates compiled templates from vendored source templates. Include `src/templates.mojo` changes with template edits. The native adapters are an unsafe boundary; changes should run the sanitizer/fuzzer gate as well as relevant HTTP and fault-injection tests. Keep expensive network/decoder/crypto work outside write transactions and retain authorization checks at admission.

Performance results must identify revisions, patches, binaries, image/toolchain, seed, CPU allocation, warmups, repetitions, compression/cache behavior and completed background work. Use `bench/durable.py`, not the historical HTTP-only posting table. Retain every round and failed gate. Do not present the local reference patches as stock Rust/C results.

Before requesting an upstream port/README entry, provide the commit, compatibility matrix, build/test instructions, license/provenance and complete benchmark receipts to the reviewing maintainers. This local repository has no accepted upstream release owner or public security-reporting address yet; the submitting maintainer must arrange those with the receiving project before a public release. No PR, release, registry upload or remote CI is created automatically by the local tooling.
