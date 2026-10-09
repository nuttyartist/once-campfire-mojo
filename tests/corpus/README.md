# Rails-generated Action Text fixtures

`generate.rb` is the MIT-licensed upstream Rust reference generator with one extra field: `body_html`, produced by the real `message.body.to_s` pipeline. `expected.json` was generated from the local Rails reference image with 200 seeded fuzz cases and 200 seeded mutation cases (658 total), plus 54 URL cases. Records, signatures and names are disposable test data.

Run the generator with a fresh SQLite database and the reference Rails image; set `RICHTEXT_INPUT`, `RICHTEXT_OUTPUT`, `RICHTEXT_FUZZ_CASES=200`, and `RICHTEXT_MUTATION_CASES=200`. It requires the original Campfire gems/assets. The normal Mojo tests only read this checked-in expected output and require no Rails runtime.

The checker compares DOM structure, attributes and text (including nested JSON/HTML editor payloads), allowing whitespace/attribute ordering differences. It independently compares plain text, verified mention ids, and preview URLs. Documented Rust-compatible exceptions: omit missing records from editor values; render a missing mention marker rather than fail the entire message; strip DOM-clobbering `name` attributes; escape attribute brackets before autolinking. No arbitrary case-name exclusions are used.
