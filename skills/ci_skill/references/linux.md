# Linux CI / Release Build Fixes

## System Dependencies

```bash
sudo apt-get update
sudo apt-get install -y libgmp-dev libssl-dev pkg-config liblzma-dev
```

## Tree-sitter C Library

Must be built from source and installed system-wide:

```bash
git clone --depth 1 --branch v0.26.8 https://github.com/tree-sitter/tree-sitter.git /tmp/tree-sitter-lib
cd /tmp/tree-sitter-lib && make && sudo make install && sudo ldconfig
```

This installs `libtree-sitter.so` to `/usr/local/lib/` and headers to `/usr/local/include/`.

`pkg-config` resolves the library path for Crystal's `@[Link("tree-sitter", pkg_config: "tree-sitter")]` annotation.

## Dynamic library loading

Linux has full POSIX `dlopen`/`dlsym` support via `LibC.dlopen` / `LibC.dlsym`.

## Shared library extension

Linux uses `.so`.

## Tree-sitter CLI

Install globally via npm:
```bash
npm install -g tree-sitter-cli
```

Or use the `setup_grammars.cr` script which tries `Process.run("tree-sitter")` then `Process.run("npx", ["tree-sitter"])`.
