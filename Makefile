# Build the Rust native module and place it where the Lua loader expects it
# (lua/lockfile_native.<ext>), plus run the test suites.

CARGO ?= cargo
NVIM ?= nvim
LIB := lockfile_native

UNAME := $(shell uname -s)
ifeq ($(OS),Windows_NT)
	EXT := dll
	BUILT := target/release/$(LIB).dll
else ifeq ($(UNAME),Darwin)
	EXT := so
	BUILT := target/release/lib$(LIB).dylib
else
	EXT := so
	BUILT := target/release/lib$(LIB).so
endif

DEST := lua/$(LIB).$(EXT)

.PHONY: all build test test-rust test-lua clean

all: build

build:
	$(CARGO) build --release
	cp $(BUILT) $(DEST)

test: test-rust test-lua

test-rust:
	$(CARGO) test

test-lua: build
	$(NVIM) --headless --noplugin -u NONE -l tests/run.lua

clean:
	$(CARGO) clean
	rm -f $(DEST)
