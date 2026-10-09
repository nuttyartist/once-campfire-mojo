MOJO ?= mojo
CC = clang
SQLITE_LIB ?= -lsqlite3
CFLAGS ?= -O3 -Wall -Wextra -Werror

.PHONY: all clean
all: build/campfire

build/platform.o: native/platform.c
	mkdir -p build
	$(CC) $(CFLAGS) -fPIC -c $< -o $@

build/campfire: $(wildcard src/*.mojo) build/platform.o
	$(MOJO) build -O3 -I src src/main.mojo -o $@ -Xlinker build/platform.o -Xlinker $(SQLITE_LIB) -Xlinker -lm -Xlinker -lz -Xlinker -lcrypto -Xlinker -lcrypt

clean:
	rm -rf build
