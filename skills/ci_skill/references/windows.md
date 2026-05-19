# Windows CI / Release Build Fixes

## Tree-sitter C Library

The `tree_sitter` Crystal shard uses `@[Link("tree-sitter", pkg_config: "tree-sitter")]` which requires the tree-sitter C library to be available at link time.

On Windows (MSVC), the library must be a `.lib` file findable by the MSVC linker.

### Install tree-sitter C library on Windows

```bash
git clone --depth 1 --branch v0.26.8 https://github.com/tree-sitter/tree-sitter.git /tmp/tree-sitter-lib
cd /tmp/tree-sitter-lib
cmake -B build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF
cmake --build build --config Release
cmake --install build --prefix /c/tree-sitter
```

The static library `.lib` will be installed to `C:\tree-sitter\lib\tree-sitter.lib`.

### Make .lib findable by Crystal compiler

Copy the built `.lib` into Crystal's bundled library directory:

```bash
CRYSTAL_LIB=$(dirname $(command -v crystal))/../lib
cp /c/tree-sitter/lib/tree-sitter.lib "$CRYSTAL_LIB/"
```

Also set environment variables:
```bash
echo "LIB=/c/tree-sitter/lib" >> $GITHUB_ENV
echo "INCLUDE=/c/tree-sitter/include" >> $GITHUB_ENV
```

## LibC Type Portability

Crystal's `LibC` module on Windows (MSVC) does not define these C99 stdint.h aliases:
- `LibC::UInt32T` → Use `UInt32`
- `LibC::UInt64T` → Use `UInt64`

These are **compile-time errors** (`undefined constant`) on Windows.

Other `LibC` types that ARE defined on Windows:
- `LibC::Char` (Int8)
- `LibC::Int` (Int32)
- `LibC::SizeT` (UInt64)
- `LibC::Long` (Int32 — note: 32-bit on Windows LLP64 vs 64-bit on Unix LP64)

## Dynamic Library Loading

Windows does not have POSIX `dlopen`/`dlsym`. Use platform conditionals:

```crystal
private def open_shared_library(path : String) : Void*
  {% if flag?(:win32) %}
    LibC.LoadLibraryA(path)
  {% else %}
    LibC.dlopen(path, LibC::RTLD_LAZY | LibC::RTLD_LOCAL)
  {% end %}
end

private def lookup_shared_symbol(handle : Void*, name : String) : Void*
  {% if flag?(:win32) %}
    LibC.GetProcAddress(handle, name)
  {% else %}
    LibC.dlsym(handle, name)
  {% end %}
end
```

## Shared Library Extension

Windows uses `.dll` not `.so` or `.dylib`:

```crystal
private def shared_library_extension : String
  {% if flag?(:darwin) %}
    "dylib"
  {% elsif flag?(:win32) %}
    "dll"
  {% else %}
    "so"
  {% end %}
end
```

## Shell quirks on Windows GitHub runners

- The `which` command in Git Bash on Windows cannot find `.exe` files reliably — prefer `Process.run` for executable detection
- `pkg-config` is not available by default on Windows — don't rely on it
- MSVC linker needs `/LIBPATH:` flag, but passing it through Crystal's `--link-flags` can mangle paths with `$LIBPATH` env var interference
