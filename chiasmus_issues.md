# Chiasmus Release Follow-up

Prepared 2026-10-19 for `dsisnero/chiasmus.cr`. Crystal Forge now uses one
manifest-verified cache installation per platform and release tag. No Chiasmus
files were changed as part of this work.

## Verification Update — 2026-10-19

- The local release-smoke, platform-requirements, and supported-grammar work
  described in items 4, 5, and 7 was already present in commit `2b45ec7`.
  This follow-up adds executable/path and CLI-option preflights to the smoke
  test, plus manifest verification of a nonempty build ID and executable Unix
  CLIs. Regression tests cover those checks.
- The macOS archive from build-only run `39092959719` (source commit `37bb0a2`)
  passed manifest verification and the strengthened Java, Go, and large-Rust
  smoke test. Crystal Forge's resolver accepted that unpacked archive, its
  Java tree-sitter preflight passed, and reconciliation produced a bundle.
- Published `v0.3.2` has GitHub asset `sha256:` digests and passed the Crystal
  Forge installer's pinned online and offline resolution on macOS. An
  unavailable offline pin failed closed.
- A new release containing the P78 bundle cache and these follow-up checks is
  **not yet published or verified on all three platforms**. The last build-only
  run predates commit `2b45ec7` and the fixes above. Items 1 and 2 remain open
  for that release; clean-host dependency verification in item 6 is also open.
- The inspected macOS archive still references absolute Homebrew paths for
  SQLite, OpenSSL, and tree-sitter. `docs/RELEASES.md` documents those runtime
  prerequisites, but the archive must not be described as self-contained.

## Already Present in the Local Chiasmus Checkout

The inspected `.github/workflows/release.yml` already has Linux x86_64,
macOS aarch64, and Windows x86_64 builds, all five required CLIs, manifest
creation/verification, archive extraction, and `release_smoke.py` before upload.
It also generates `SHA256SUMS` when publishing. Preserve these safeguards;
their presence in source does not establish that a published build passed.

## Remaining Work and Acceptance Criteria

1. Run the release workflow on all three platforms and publish a stable tagged
   release after every packaging and runtime check passes. Provide the run URL
   and tag. Ensure the GitHub release asset API supplies `digest: sha256:<hex>`;
   the skill currently verifies that field, not the separate SHA256SUMS file.

2. Test the exact archive through Crystal Forge's `resolve_toolchain.py` as a
   consumer. Keep archive names `chiasmus-Linux-x86_64-<tag>.tar.gz`,
   `chiasmus-macOS-aarch64-<tag>.tar.gz`, and
   `chiasmus-Windows-x86_64-<tag>.zip`. Each must unpack under `chiasmus/` and
   contain `toolchain-manifest.json`, discover/facts/parity/plan/complete CLIs
   (`.exe` on Windows), and native Java, Go, and Crystal grammar libraries.

3. Keep the v1 manifest compatible: `manifest_version: 1`, platform keys
   `linux-x86_64`, `darwin-aarch64`, `windows-x86_64`, a nonempty `build_id`,
   SHA-256 and size records for every packaged file except the manifest, and
   capability groups containing `discover: [tree-sitter]`,
   `facts: [typed-declarations]`, and `parity: [bundle]`. Include runtime DLLs
   and shared libraries in the file records. Unix CLIs must be executable.

4. Strengthen `release_smoke.py`: change the subprocess working directory to
   an isolated temporary directory, resolve executable paths first, and exclude
   source-checkout/cache grammar fallbacks. Assert actual tree-sitter parser
   provenance as well as finding Widget. The existing smoke checks generated
   report file existence; also inspect expected entity mappings and surface
   results so empty/header-only or incorrect reports fail.

5. Exercise plan and complete beyond `--help`: generate planning output and
   evaluate a small complete/incomplete fixture. Cover `--cache-dir`, facts
   `--declarations-out`, parity `--source-declarations`,
   `--target-declarations`, and `--bundle-dir`, which the skill invokes.

6. Verify dynamic dependencies from the extracted package on clean hosts.
   Bundle redistributable libraries or document supported prerequisites;
   avoid dependencies on build-machine Homebrew/vcpkg paths. Check DLL loading
   on Windows and native library resolution on Linux/macOS. Windows shell
   integration also needs Git Bash, Ruby, and Python 3 on the consumer side.

7. Publish the actual supported language set. The current packaging loop does
   not include every grammar the discovery library may support (for example
   C#); either package and test additional grammars or document the subset.
   macOS Intel and Linux ARM64 are optional additional build targets, not
   covered by the current three-platform matrix.

## Consumer Verification After Publication

From the Crystal Forge parity skill directory:

```bash
bash scripts/install_chiasmus_toolchain.sh --version <stable-tag>
export CHIASMUS_VERSION=<stable-tag>
bash scripts/verify_skill_install.sh /path/to/port java tree-sitter
bash scripts/reconcile_parity.sh /path/to/port vendor/upstream java src
```

Repeat with `CHIASMUS_TOOLCHAIN_OFFLINE=1` and confirm the pinned verified cache
works without network access. An unavailable pin must fail rather than switch
versions. Record real cross-platform results separately from fixture tests.
