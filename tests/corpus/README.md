# Rails-generated Action Text fixtures

`generate.rb` is the MIT-licensed upstream Rust reference generator extended with `body_html` from the real `message.body.to_s` pipeline and current Lexxy editor values from public Rails helper APIs. `expected.json` was generated from the exact original Rails `b52b244` image (revision label verified) with 200 seeded fuzz cases and 200 seeded mutation cases (658 total), plus 54 URL cases. Records, signatures and names are disposable test data.

Use `bash tools/regenerate-corpus.sh` for the pinned current-original regeneration. To run it manually with a fresh SQLite database and the reference Rails image; set `RICHTEXT_INPUT`, `RICHTEXT_OUTPUT`, `RICHTEXT_FUZZ_CASES=200`, and `RICHTEXT_MUTATION_CASES=200`. It requires the original Campfire gems/assets. The normal Mojo tests only read this checked-in expected output and require no Rails runtime.

The checker compares DOM structure, attributes and text (including nested JSON/HTML editor payloads), allowing whitespace/attribute ordering differences. It independently compares plain text, verified mention ids, and preview URLs. Documented Rust-compatible exceptions: omit missing records from editor values; render a missing mention marker rather than fail the entire message; strip DOM-clobbering `name` attributes; escape attribute brackets before autolinking. No arbitrary case-name exclusions are used.

`rails_compat.json` and `storage.json` are vendored independent Ruby-generated vectors from Rust upstream `6dae2fd`; normal tests do not need the Rust checkout. See `PROVENANCE.md`.
