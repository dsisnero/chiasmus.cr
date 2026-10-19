# Release Toolchain Requirements

Release archives contain discover, facts, parity, plan, and complete CLIs, their
matching grammar libraries, and toolchain-manifest.json. Install the whole
archive as a unit. Independent binary replacement is unsupported.

## Supported Release Platforms

| Archive platform | Architecture |
|---|---|
| Linux | x86_64 |
| macOS | aarch64 (Apple Silicon) |
| Windows | x86_64 |

macOS Intel and Linux ARM64 are not produced by the current release matrix.
A successful build-runner smoke test does not establish support for every OS
version or a host without the runner's system libraries.

## Runtime Libraries

The binaries are dynamically linked. The archives are not fully self-contained.

For the published macOS v0.3.2 parity tools, inspection with `otool -L` shows
Homebrew dependencies at these paths:

- `/opt/homebrew/opt/sqlite/lib/libsqlite3.dylib`
- `/opt/homebrew/opt/openssl@4/lib/libssl.4.dylib`
- `/opt/homebrew/opt/openssl@4/lib/libcrypto.4.dylib`
- `/opt/homebrew/opt/tree-sitter/lib/libtree-sitter.0.27.dylib`

Install compatible libraries before running that release. A different major
OpenSSL or tree-sitter version does not satisfy these paths automatically.
Never create compatibility symlinks between incompatible library versions.

Linux consumers must provide the shared libraries reported by `ldd` for their
release binaries. The release is built on ubuntu-latest; compatibility with older
glibc distributions is not established. Windows packages include sqlite3.dll
next to the executables; keep runtime DLLs beside the tools.

For each release, inspect every executable and grammar with the platform loader
tools (`otool -L`, `ldd`, or Windows dependency inspection). To claim standalone
portability, bundle redistributable dependencies with package-relative loader
paths and test on clean hosts. That clean-host verification remains required.

## Packaged Grammars

The current packaging loop attempts to include these native grammars:

Crystal, Go, Java, JavaScript, Python, Ruby, Rust, Scala, TypeScript, and TSX.

Only Java, Go, and Crystal are mandatory in the manifest. Inspect the archive's
manifest for the actual shipped files. Library/extractor support for other
languages does not imply that their grammars are packaged. In particular, the
current loop does not ship C#.

## Skill Integration

Crystal Forge installs and verifies one release into
`~/.cache/chiasmus/toolchains/<platform>/<tag>`. It checks the GitHub asset
SHA-256 digest and every manifest file hash and size. Archive names and manifest
capabilities must remain compatible with its resolver. The manifest includes
all packaged runtime libraries and documentation.

The shell wrappers need Bash, Ruby, and Python 3; Windows users can use Git Bash.
Export `CHIASMUS_VERSION=<exact-tag>` to pin the skill. Offline operation requires
a verified cache or a complete manually provisioned toolchain.

Run the release smoke tests against the extracted archive before publishing.
Also run Crystal Forge's `scripts/verify_released_toolchain.py --version <tag>`
after publication and repeat with `--offline`. Record platform-specific
results; fixture tests and local macOS results do not verify Linux or Windows.
