# Cross-Platform Build & Release Plan

## Current State

| Component | macOS (dylib) | Linux (so) | Windows (dll) |
|-----------|:---:|:---:|:---:|
| Discovery grammar_loader.cr | Yes | Yes | Yes |
| Graph grammar_manager.cr | Yes | Yes | **No** |
| Grammar compilation scripts | Yes | Yes | **No** |
| Embedded grammars loader | Yes | Yes | **No** |
| Makefile dist target | Yes (hardcoded) | **No** | **No** |
| CI (github actions) | — | Ubuntu only | — |
| GitHub release workflow | — | — | — |

## Goal

Three CLI binaries (`chiasmus`, `chiasmus-discover`, `chiasmus-grammar`) built and released as artifacts for:

- **macOS** — ARM64 (apple silicon) + x86_64
- **Linux** — x86_64 (static) + ARM64
- **Windows** — x86_64 (MSVC or mingw)

Each release includes compiled tree-sitter grammar libraries for all 10 languages.

---

## Phase 1: Platform Code Fixes

### 1.1 Unify platform extension detection

**Current problem:** Each file independently chooses `dylib` vs `so` vs `dll` via compile-time macro. `grammar_operations.cr`, `grammar_manager.cr`, `embedded_grammars.cr`, `setup_grammars.cr`, and `build_static.cr` lack Windows support.

**Fix:** Extract `shared_library_extension` into a single location (`src/chiasmus/platform.cr`) and import everywhere.

```crystal
# src/chiasmus/platform.cr
module Chiasmus::Platform
  def self.shared_library_extension : String
    {% if flag?(:darwin) %}
      "dylib"
    {% elsif flag?(:win32) %}
      "dll"
    {% else %}
      "so"
    {% end %}
  end

  def self.library_prefix : String
    {% if flag?(:win32) %}
      ""
    {% else %}
      "lib"
    {% end %}
  end

  def self.executable_extension : String
    {% if flag?(:win32) %}
      ".exe"
    {% else %}
      ""
    {% end %}
  end
end
```

### 1.2 Fix all grammar scripts for Windows

Update these files to use `Platform.shared_library_extension`:

| File | Current state | Fix |
|------|--------------|-----|
| `setup_grammars.cr` | Only dylib/so | Add dll, dll naming conventions |
| `setup_grammars_new.cr` | Wrapper, uses CLI | Verify CLI handles Windows |
| `download_grammars.cr` | Only dylib/so | Add dll |
| `grammar_operations.cr` | Only dylib/so | Add dll, mingw compiler options |
| `grammar_manager.cr` | Only dylib/so | Add dll |
| `embedded_grammars.cr` | Only dylib/so | Add dll |
| `build_static.cr` | Only dylib/so | Add dll |

### 1.3 DLL symbol export on Windows

Windows shared libraries require explicit symbol exports. The tree-sitter grammars built with `tree-sitter build` on Windows produce `tree-sitter-{lang}.dll`. Verify that `LibC.dlopen` / `dlopen` works on Windows with Crystal's FFI. Crystal on Windows uses `win_delay_load_hook` — test with a minimal grammar first.

### 1.4 Path handling on Windows

- `File.join` works cross-platform.
- `Dir.glob` works cross-platform.
- `LibC.dlopen` uses `LoadLibraryA` on Windows.
- `find_grammar_library` in `grammar_loader.cr` already handles path separation correctly via `File.join`.

---

## Phase 2: CI Matrix

### 2.1 Multi-platform CI workflow

Replace the single `ubuntu-latest` job with a matrix:

```yaml
name: CI

on:
  push: { branches: [main] }
  pull_request: { branches: [main] }

jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
        crystal: [latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: crystal-lang/install-crystal@v1
        with: { crystal: ${{ matrix.crystal }} }

      # Linux: apt deps
      - if: runner.os == 'Linux'
        run: sudo apt-get install -y libgmp-dev libssl-dev pkg-config swi-prolog

      # macOS: brew deps
      - if: runner.os == 'macOS'
        run: brew install gmp openssl pkg-config swi-prolog

      # Windows: no extra deps needed (Crystal bundles them)

      - run: shards install
      - run: crystal tool format --check src spec
      - run: bin/ameba src
      - run: crystal spec
```

### 2.2 Grammar compilation in CI

For discovery specs that need grammars, add a grammar compilation step:

```yaml
      # Install tree-sitter CLI (all platforms)
      - uses: baptiste0928/cargo-install@v3
        with: { crate: tree-sitter-cli }

      # Compile all 10 grammar libraries
      - run: crystal run scripts/setup_grammars.cr
```

### 2.3 Platform-specific considerations

| Platform | System deps | Z3 | SWI-Prolog | Grammar compiler |
|----------|------------|-----|-----------|-----------------|
| Ubuntu | `libgmp-dev libssl-dev` | via crystal-z3 shard | `apt install swi-prolog` | `tree-sitter` CLI via cargo |
| macOS | `gmp openssl` via brew | via crystal-z3 shard | `brew install swi-prolog` | `tree-sitter` CLI via cargo |
| Windows | None (bundled) | Optional (skip z3 tests) | Optional (skip prolog tests) | `tree-sitter` CLI via cargo |

On Windows, Z3 and SWI-Prolog may not be available. Tests that require them should be tagged and skipped:
```crystal
{% if flag?(:win32) %}
  pending "Z3 not available on Windows"
{% else %}
  it "solves with z3" { ... }
{% end %}
```

Or use Crystal's `tags`:
```crystal
it "solves with z3", tags: "z3" { ... }
```
```bash
crystal spec --tag="~z3"  # skip z3 tests on Windows
```

---

## Phase 3: Release Artifacts

### 3.1 GitHub Release workflow

```yaml
name: Release

on:
  push:
    tags: ['v*']

jobs:
  build:
    strategy:
      fail-fast: false
      matrix:
        include:
          - { os: ubuntu-latest,   arch: x86_64,  ext: "" }
          - { os: macos-latest,    arch: x86_64,  ext: "" }
          - { os: macos-latest,    arch: aarch64, ext: "" }
          - { os: windows-latest,  arch: x86_64,  ext: ".exe" }
    runs-on: ${{ matrix.os }}

    steps:
      - uses: actions/checkout@v4
        with: { submodules: recursive }

      - uses: crystal-lang/install-crystal@v1
        with: { crystal: latest }

      # Install tree-sitter CLI
      - uses: baptiste0928/cargo-install@v3
        with: { crate: tree-sitter-cli }

      - run: shards install

      # Compile grammars
      - run: crystal run scripts/setup_grammars.cr

      # Build all three binaries
      - run: |
          mkdir -p dist/chiasmus/grammars
          crystal build --release --static -o dist/chiasmus/chiasmus${{ matrix.ext }} src/chiasmus.cr
          crystal build --release --static -o dist/chiasmus/chiasmus-discover${{ matrix.ext }} src/chiasmus_discover.cr
          crystal build --release --static -o dist/chiasmus/chiasmus-grammar${{ matrix.ext }} src/chiasmus_grammar.cr

      # Copy grammar libraries
      - run: |
          ext=${{ runner.os == 'macOS' && 'dylib' || runner.os == 'Linux' && 'so' || 'dll' }}
          for lang in ruby python java go rust scala javascript typescript tsx crystal; do
            lib=libtree-sitter-$lang.$ext
            find vendor/grammars -name "$lib" -exec cp {} dist/chiasmus/grammars/ \;
          done

      # Package
      - run: |
          cd dist
          tar czf chiasmus-${{ runner.os }}-${{ matrix.arch }}-${{ github.ref_name }}.tar.gz chiasmus/

      # Upload artifact
      - uses: actions/upload-artifact@v4
        with:
          name: chiasmus-${{ runner.os }}-${{ matrix.arch }}
          path: dist/chiasmus-${{ runner.os }}-${{ matrix.arch }}-*.tar.gz

  publish:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
      - run: ls -la */
      - uses: softprops/action-gh-release@v2
        with:
          files: '**/*.tar.gz'
          generate_release_notes: true
```

### 3.2 Artifact naming convention

```
chiasmus-{platform}-{arch}-{version}.tar.gz

Examples:
  chiasmus-linux-x86_64-v0.2.0.tar.gz
  chiasmus-macos-aarch64-v0.2.0.tar.gz
  chiasmus-windows-x86_64-v0.2.0.tar.gz
```

Each archive contains:
```
chiasmus/
  chiasmus              (or chiasmus.exe)
  chiasmus-discover     (or chiasmus-discover.exe)
  chiasmus-grammar      (or chiasmus-grammar.exe)
  grammars/
    libtree-sitter-ruby.{dylib,so,dll}
    libtree-sitter-python.{dylib,so,dll}
    libtree-sitter-java.{dylib,so,dll}
    libtree-sitter-go.{dylib,so,dll}
    libtree-sitter-rust.{dylib,so,dll}
    libtree-sitter-scala.{dylib,so,dll}
    libtree-sitter-javascript.{dylib,so,dll}
    libtree-sitter-typescript.{dylib,so,dll}
    libtree-sitter-tsx.{dylib,so,dll}
    libtree-sitter-crystal.{dylib,so,dll}
```

---

## Phase 4: Verification

### 4.1 Platform smoke test script

Create `scripts/smoke_test.cr` that validates:
1. All three binaries exist and are executable
2. Grammar libraries are present and loadable
3. Each discoverable language parses a trivial source file
4. Output matches expected ID format

```bash
# Quick smoke test
./chiasmus-discover --language python --source "class Foo: pass" --inline
# Expected: test.py::class::Foo  class  ported  -  parser=tree-sitter
```

### 4.2 CI verification matrix

Add a post-build verification job in CI:

```yaml
  verify:
    needs: build
    strategy:
      matrix:
        language: [python, go, java, rust, javascript, typescript, ruby, crystal, scala]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with: { name: chiasmus-Linux-x86_64 }
      - run: |
          tar xzf *.tar.gz
          ./chiasmus/chiasmus-discover --language ${{ matrix.language }} \
            --dir vendor/chiasmus --parser tree-sitter | head -5
```

### 4.3 Manual verification checklist

For each platform, verify:

- [ ] `chiasmus --help` prints usage
- [ ] `chiasmus-discover --language python --dir vendor/chiasmus` returns declarations
- [ ] `chiasmus-discover --language go --dir vendor/chiasmus` returns declarations
- [ ] `chiasmus-discover --parser regex` falls back cleanly
- [ ] `chiasmus-grammar list` shows available grammars
- [ ] `chiasmus-grammar compile python` compiles grammar
- [ ] All 10 languages discoverable via tree-sitter
- [ ] Parser mode reported in output notes column

---

## Phase 5: Implementation Order

| Step | Files | Effort |
|------|-------|--------|
| 1. Extract `Platform` module | `src/chiasmus/platform.cr` | Small |
| 2. Update all grammar scripts to use Platform | 6 files | Small |
| 3. Fix path/encoding issues for Windows | `grammar_loader.cr`, `grammar_manager.cr` | Medium |
| 4. CI matrix (3 OS) | `.github/workflows/ci.yml` | Small |
| 5. CI grammar compilation step | `.github/workflows/ci.yml` | Small |
| 6. Tag z3/prolog tests for Windows | `spec/**/*.cr` | Medium |
| 7. Release workflow | `.github/workflows/release.yml` | Medium |
| 8. Smoke test script | `scripts/smoke_test.cr` | Small |
| 9. Verify all platforms in CI | Watch CI logs | Manual |
| 10. First tagged release | `git tag v0.2.0` | Manual |

---

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| Static linking fails on macOS | Fall back to dynamic linking with `install_name_tool` for grammar libraries |
| Crystal Windows support is beta | Test early, skip z3/prolog on Windows, focus on discovery + grammar CLI |
| tree-sitter CLI not available on Windows via cargo | Use pre-built tree-sitter binary from GitHub releases |
| Grammar compilation fails on Windows (MSVC vs MinGW) | Use MinGW gcc for compatibility with Crystal's GCC-based linking |
| `LibC.dlopen` doesn't work with `.dll` on Windows | Use `LoadLibraryW` via Win32 API if needed |
| SWI-Prolog not available on Windows via apt/brew | Skip prolog tests on Windows, focus on discovery (Phase 6 adds native support) |

---

## Phase 6: Windows Z3 & Prolog Support (Bonus)

Deferred until all other cross-platform work is complete and verified.

### 6.1 Z3 on Windows

**Current state:** The `crystal-z3` shard links against `libz3`. On Windows this requires `z3.lib` or `libz3.dll`.

**Approach:**

1. **Download pre-built Z3 binaries** in CI:
   ```yaml
   - name: Install Z3
     if: runner.os == 'Windows'
     run: |
       curl -L -o z3.zip https://github.com/Z3Prover/z3/releases/download/z3-4.13.0/z3-4.13.0-x64-win.zip
       7z x z3.zip
       cp z3-*/bin/libz3.dll C:/Windows/System32/
       cp z3-*/include/z3*.h /path/to/crystal-z3/ext/
   ```

2. **Update crystal-z3 shard** for Windows linking:
   - Add `@[Link("z3")]` with `ldflags: "/path/to/z3.lib"` conditional on `{% if flag?(:win32) %}`
   - Or use DLL loading via `LibC.LoadLibraryW` + `LibC.GetProcAddress`

3. **Re-enable z3 specs** on Windows:
   - Remove `{% if flag?(:win32) %}` guards from z3 specs
   - Add tagged spec run: `crystal spec --tag="z3"`

### 6.2 SWI-Prolog on Windows

**Current state:** `crolog` shard links against `libswipl`. SWI-Prolog provides official Windows installers.

**Approach:**

1. **Download SWI-Prolog** in CI:
   ```yaml
   - name: Install SWI-Prolog
     if: runner.os == 'Windows'
     run: |
       curl -L -o swipl.exe https://www.swi-prolog.org/download/stable/bin/swipl-9.2.7-1.x64.exe
       ./swipl.exe /S /D=C:\swipl
       cp C:\swipl\bin\libswipl.dll C:\Windows\System32\
   ```

2. **Update crolog shard** for Windows linking:
   - Add `@[Link("swipl")]` with Windows library path
   - Windows SWI-Prolog uses `libswipl.dll.a` for GCC linking
   - May need `--static` linking of swipl or DLL-based loading

3. **Handle Prolog temp files on Windows:**
   - Crystal's `File.tempfile` works cross-platform
   - `Process.run("swipl", [...])` needs `swipl.exe` on PATH
   - Verify path escaping for backslash paths in Prolog consult directives

4. **Re-enable prolog specs** on Windows:
   - Remove `{% if flag?(:win32) %}` guards from prolog solver specs
   - Add tagged spec run: `crystal spec --tag="prolog"`

### 6.3 Verification for Windows Z3/Prolog

```yaml
  verify-windows-solvers:
    needs: build
    if: runner.os == 'Windows'
    runs-on: windows-latest
    steps:
      - uses: actions/download-artifact@v4
        with: { name: chiasmus-Windows-x86_64 }
      - run: |
          tar xzf *.tar.gz
          # Test Z3 verification
          echo "(declare-const x Bool) (assert x) (check-sat)" | ./chiasmus/chiasmus.exe --verify --solver z3
          # Test Prolog verification
          ./chiasmus/chiasmus.exe --verify --solver prolog --query "member(X, [a,b,c])"
```

### 6.4 Phase 6 Implementation Order

| Step | Effort | Prerequisites |
|------|--------|--------------|
| 1. Z4 DLL loading in crystal-z3 shard | Medium | Phases 1-5 complete |
| 2. SWI-Prolog DLL loading in crolog shard | Medium | Phases 1-5 complete |
| 3. CI install scripts for z3 + swipl on Windows | Small | Steps 1-2 |
| 4. Re-enable solver specs on Windows | Small | Steps 1-3 |
| 5. Solver verification in CI | Small | Steps 1-4 |
