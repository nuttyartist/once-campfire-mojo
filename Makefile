.DEFAULT_GOAL := all
MOJO ?= mojo
CC = clang
SQLITE_LIB ?= build/sqlite3.o
CFLAGS ?= -O3 -Wall -Wextra -Werror -I/usr/include/libxml2 $(shell pkg-config --cflags vips)

GUMBO_OBJECTS := $(patsubst vendor/gumbo/src/%.c,build/gumbo/%.o,$(wildcard vendor/gumbo/src/*.c))

build/gumbo/%.o: vendor/gumbo/src/%.c
	mkdir -p build/gumbo
	$(CC) -O3 -std=c99 -fPIC -Ivendor/gumbo/src -c $< -o $@

build/libgumbo.a: $(GUMBO_OBJECTS)
	ar rcs $@ $^

.PHONY: all clean
all: build/campfire

build/sqlite3.o: vendor/sqlite/sqlite3.c vendor/sqlite/sqlite3.h
	mkdir -p build
	$(CC) -O3 -fPIC -DSQLITE_ENABLE_FTS5 -DSQLITE_THREADSAFE=1 -DSQLITE_DEFAULT_MEMSTATUS=0 -c $< -o $@

build/platform.o: native/platform.c
	mkdir -p build
	$(CC) $(CFLAGS) -fPIC -c $< -o $@

build/qrcodegen.o: vendor/qrcodegen/qrcodegen.c
	mkdir -p build
	$(CC) $(CFLAGS) -fPIC -c $< -o $@

build/process.o: native/process.c
	mkdir -p build
	$(CC) $(CFLAGS) -fPIC -c $< -o $@

build/transport.o: native/transport.c
	mkdir -p build
	$(CC) $(CFLAGS) -fPIC -c $< -o $@

build/runtime.o: native/runtime.c
	mkdir -p build
	$(CC) $(CFLAGS) -fPIC -c $< -o $@

src/templates.mojo: $(wildcard templates/*.html) assets/manifest.json tools/compile_templates.py
	python3 tools/compile_templates.py

build/campfire: src/templates.mojo $(wildcard src/*.mojo) build/platform.o build/runtime.o build/qrcodegen.o build/libgumbo.a build/transport.o build/process.o $(filter build/%,$(SQLITE_LIB))
	$(MOJO) build -O3 -I src src/main.mojo -o $@ -Xlinker build/platform.o -Xlinker build/runtime.o -Xlinker build/qrcodegen.o -Xlinker build/libgumbo.a -Xlinker build/transport.o -Xlinker build/process.o -Xlinker -lcurl -Xlinker $(SQLITE_LIB) -Xlinker -lm -Xlinker -lz -Xlinker -lcrypto -Xlinker -lcrypt -Xlinker -lxml2 $(foreach lib,$(shell pkg-config --libs vips),-Xlinker $(lib))

clean:
	rm -rf build
