# Run from the repository root: make -f tests/Makefile vectors
MOJO ?= mojo
ABI = -Xlinker build/platform.o -Xlinker build/runtime.o -Xlinker build/process.o -Xlinker build/qrcodegen.o -Xlinker build/transport.o -Xlinker build/libgumbo.a -Xlinker -lcurl -Xlinker -lcrypto -Xlinker build/sqlite3.o -Xlinker -lm -Xlinker -lcrypt -Xlinker -lz -Xlinker -lxml2 -Xlinker -lvips -Xlinker -lglib-2.0 -Xlinker -lgobject-2.0
.PHONY: vectors
vectors: build/push-fixture build/push-vector build/compat-vectors
	build/push-vector
	build/compat-vectors
	python3 tests/push_receiver.py
build/push-fixture: tests/push_fixture.mojo $(wildcard src/*.mojo native/*) build/runtime.o build/platform.o build/process.o
	$(MOJO) build -O3 -I src $< -o $@ $(ABI)
build/push-vector: tests/push_vector.mojo $(wildcard src/*.mojo native/*) build/runtime.o build/platform.o build/process.o
	$(MOJO) build -O3 -I src $< -o $@ $(ABI)
build/compat-vectors: tests/compat_vectors.mojo $(wildcard src/*.mojo native/*) build/runtime.o build/platform.o build/process.o
	$(MOJO) build -O3 -I src $< -o $@ $(ABI)

build/richtext-corpus: tests/richtext_corpus.mojo $(wildcard src/*.mojo)
	$(MOJO) build -O3 -I src $< -o $@ $(ABI)

.PHONY: richtext
richtext: build/richtext-corpus
	SECRET_KEY_BASE=richtext-corpus-disposable-local-key-0000000000000000000000000000000 build/richtext-corpus > build/richtext-corpus.jsonl
	python3 tests/richtext_check.py

build/json-encoding: tests/json_encoding.mojo $(wildcard src/*.mojo native/*) build/platform.o
	$(MOJO) build -O3 -I src $< -o $@ $(ABI)
.PHONY: json-encoding
json-encoding: build/json-encoding
	python3 tests/json_encoding.py
