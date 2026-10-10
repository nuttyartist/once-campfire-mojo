# Byte and native-boundary contract

Application modules use `String` only for valid UTF-8 text. `Bytes` owns a
`List[UInt8]` for HTTP bodies, socket buffers, uploads, downloads, compression,
WebSocket frames/fragments, Marshal serialization, hashes, keys and ciphertext.
Encoding text as bytes is allowed implicitly; decoding bytes requires `.text()`,
which validates UTF-8 and raises on invalid input. Binary data is never decoded
lossily. Spans borrow their owners through Mojo origins rather than raw pointers.

`src/native_boundary.mojo` is the sole Mojo FFI boundary. Its typed APIs derive
pointers from live borrowed buffers, validate lengths and output capacities,
check fixed cryptographic key sizes, reject NUL in C-string arguments, and copy
returned native allocations into owned byte buffers before freeing them with the
correct allocator. Native text is decoded with checked UTF-8 constructors.
No unchecked UTF-8 constructor is permitted anywhere in the Mojo source.

The native SQL owner keeps the database and prepared-statement handles together.
It resets statements on errors, including text decoding failures, and finalizes
all statements before closing the database. SQL columns exposed by this API are
text; binary SQL values must not be treated as text.

DOM integers are opaque, non-reused registry identifiers, not addresses. The C
adapter validates each identifier and its resource kind before accessing libxml.
Removing/replacing nodes invalidates their descendants and attributes; freeing
a document invalidates all its borrowed identifiers. Repeated cleanup and stale
or forged identifiers cannot dereference freed nodes. DOM calls are synchronous
on each worker's single event-loop thread; a future threaded DOM implementation
must add synchronization to the native registry.

File descriptors are operating-system handles. The connection owns its socket,
spooled upload and active download; download ownership moves from the request's
pending response to the connection. Cleanup closes and resets those handles.
Process supervision, socket readiness and file streaming retain the existing
forked-worker architecture and durability guarantees.

## Audit and regression coverage

The October 2026 audit covered every application Mojo module, including binary
flows, FFI arguments, buffer capacities, native ownership, byte slicing, input
lengths, UTF-8 boundaries and resource cleanup. Additional fixes include rejecting
non-ASCII malformed signature envelopes before byte slicing, checking helper
allocation/range lengths, handling Ruby's minimum signed integer without signed
absolute-value overflow, and handling single-character quoted form values without
an invalid slice. Complete chunk lines/trailers and request headers obey their
size limits even when the terminating delimiter arrives in the same read.

`tools/check.sh` runs these regressions on both CI architectures:

- `source_safety.py`: rejects FFI/raw-pointer APIs outside the boundary, native SQL
  field access outside its owner, and unchecked UTF-8 constructors anywhere.
- `byte_safety.mojo` and `byte_safety.py`: all 256 byte values, owned copies,
  invalid UTF-8 and ranges, binary framing/chunks/spooling, crypto buffer sizes,
  malformed cookies, SQL recovery, DOM stale handles, and six independently
  checked Python wire encodings (including gzip, SHA-256 and Ruby Marshal).
- `byte_http.py`: real HTTP and masked WebSocket traffic, split multibyte Unicode,
  arbitrary ping bytes, invalid text, binary multipart false delimiters, exact
  close-code bytes, and unchanged worker processes after malformed requests.
- Existing independent Rails fixtures, application tests, media, streaming upload,
  encrypted push delivery, migration, browser, recovery and durability gates.
- Native ASan/UBSan fuzzing, extended to invalidated DOM nodes and attributes,
  forged identifiers and repeated cleanup.

The source rule is an architectural regression guard, not a proof of memory
safety. ASan/UBSan instrument the C adapters in the native fuzz harness, not Mojo
application code. The boundary and its C/library dependencies remain trusted
native code and still require review when changed. Passing tests does not make
this implementation formally verified.
