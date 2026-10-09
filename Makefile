MOJO ?= mojo
CC = clang
SQLITE_LIB ?= -lsqlite3
CFLAGS ?= -O3 -Wall -Wextra -Werror -I/usr/include/libxml2

.PHONY: all clean
all: build/campfire

build/platform.o: native/platform.c
	mkdir -p build
	$(CC) $(CFLAGS) -fPIC -c $< -o $@

src/templates.mojo: $(wildcard templates/*.html) assets/manifest.json tools/compile_templates.py
	python3 tools/compile_templates.py

build/campfire: src/templates.mojo $(wildcard src/*.mojo) build/platform.o
	$(MOJO) build -O3 -I src src/main.mojo -o $@ -Xlinker build/platform.o -Xlinker $(SQLITE_LIB) -Xlinker -lm -Xlinker -lz -Xlinker -lcrypto -Xlinker -lcrypt -Xlinker -lxml2

clean:
	rm -rf build
