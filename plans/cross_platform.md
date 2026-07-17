# Cross-Platform Parity Maintenance Plan

## Why This Exists

The `cross-language-crystal-parity` skill is strong at vendor API/test drift,
but cross-platform work in this repo cuts across three categories:

- vendor-backed runtime behavior
- Crystal-native packaging/release behavior
- CI/signoff workflow

That means platform work is easy to do sloppily: people either ignore the
inventory entirely, or they try to force CI/release changes into fake upstream
parity rows. This document exists to make platform work fit the parity skill
cleanly.

Use this file when the task is any of:

- grammar loading breaks on one OS
- packaging/release assets drift by platform
- CI proves builds but not runtime behavior
- platform abstractions diverge across scripts and runtime code

Do not use this file as a substitute for `plans/parity.md`. This is a focused
execution guide for a cross-cutting maintenance area that the main parity plan
does not slice well on its own.

## How To Use This With `cross-language-crystal-parity`

### Scope rule

Use the normal parity skill flow:

1. read the relevant upstream/runtime code
2. decide whether the work is vendor-backed, Crystal-native, or mixed
3. port/fix the smallest behavior slice
4. run drift checks and repo gates
5. update the curated artifacts that actually correspond to the work

### Inventory rule

Not every cross-platform change should create or edit inventory rows.

Touch `plans/inventory/typescript_port_inventory.tsv` only when the platform
change affects behavior that maps to upstream TypeScript items, for example:

- grammar loading behavior
- MCP/runtime behavior that changes because libraries are found or not found
- CLI/runtime behavior exposed by a tracked upstream module

Do **not** invent vendor rows for purely Crystal-native maintenance work such
as:

- GitHub Actions matrix changes
- archive naming changes
- packaging extra binaries
- local `Makefile dist` portability

Track those as Crystal-native parity-maintenance slices in this document and, if
needed, as feature entries in `plans/parity.md`, but not as fake TypeScript
inventory IDs.

When vendor-backed platform work introduces new source IDs, use:

```bash
ruby scripts/sync_port_inventory.rb \
  --manifest plans/inventory/typescript_port_inventory.tsv \
  --source vendor/chiasmus \
  --language typescript \
  --parser tree-sitter
```

That sync keeps the curated ledger source-focused. Exhaustive test drift belongs
in `plans/inventory/typescript_test_parity.tsv`, not in ad hoc inventory rows.

### Signoff rule

For platform work, "done" is stricter than "the code compiles":

- relevant Crystal specs pass
- repo gates pass (`format`, `lint`, `test` as applicable)
- parity drift checks still pass for vendor-backed changes
- the platform-specific workflow described by the feature actually works

## Current Usefulness To The Skill

This document should answer four questions for an agent using the parity skill:

1. Is this work supposed to touch the TypeScript parity ledger?
2. What is the smallest branch-sized slice to implement next?
3. What commands prove the slice is done?
4. What remains an intentional Crystal-native divergence from upstream?

## Current State

### Platform abstractions

The repo already has a central platform module:

- `src/chiasmus/platform.cr`

It provides:

- shared library extension selection
- library prefix selection
- executable extension selection
- artifact OS/arch naming helpers

This means the top-level platform abstraction problem is not "create a platform
module". The remaining problem is to make every loader, script, and packaging
path use that module consistently.

**Parity classification:** mixed.

- Runtime loader drift can be vendor-backed and may justify inventory updates.
- Script and packaging drift is Crystal-native and should stay out of vendor
  inventory.

### CLI/build surface

The repo currently builds more than the old plan assumed.

Public or semi-public binaries present in this branch:

- `chiasmus`
- `chiasmus-discover`
- `chiasmus-grammar`
- `chiasmus-parity`
- `chiasmus-facts`

Targets and build entry points currently live in:

- `shard.yml`
- `Makefile`
- `.github/workflows/ci.yml`
- `.github/workflows/release.yml`

**Parity classification:** mostly Crystal-native.

### Grammar support

There are two different "grammar sets" in the repo today:

- Legacy/minimal wrappers and embedding helpers still assume 10 languages.
- The main grammar setup pipeline already knows about a broader set:
  `ruby`, `python`, `java`, `go`, `rust`, `scala`, `javascript`,
  `typescript`, `tsx`, `crystal`, `bash`, `c`, `cpp`, `csharp`, `dart`,
  `kotlin`, `perl`, `php`, `proto`.

That mismatch is a real cross-platform problem because packaging and CI can
appear green while leaving newer grammars out of artifacts.

**Parity classification:** mixed.

- Runtime grammar availability affects vendor-backed graph/discovery behavior.
- Which grammars get shipped in release assets is Crystal-native packaging work.

### CI and release coverage

What exists now:

- `ci.yml` tests on macOS and Linux
- `ci.yml` builds CLI artifacts on macOS, Linux, and Windows
- `release.yml` builds release artifacts on macOS, Linux, and Windows

What does not exist yet:

- Windows test execution in the main spec matrix
- a complete release matrix for both major CPU families on both Unix platforms
- consistent packaging of every binary the repo now builds locally

**Parity classification:** Crystal-native signoff work.

## Verified Gaps

### 1. Duplicate platform logic still exists

Even though `src/chiasmus/platform.cr` exists, some code still hardcodes
platform logic or re-implements it.

Examples:

- `src/chiasmus/discovery/grammar_loader.cr`
  has its own private `shared_library_extension`
- `scripts/build_static.cr`
  hardcodes extension selection instead of using `Chiasmus::Platform`
- `Makefile`
  hardcodes `dylib` in `dist`

Impact:

- behavior drift between runtime loading and packaging
- Windows support regresses easily because the logic is not centralized in
  practice

Parity handling:

- If a fix changes runtime loader behavior, update inventory rows for the
  affected upstream modules.
- If a fix only updates build/package scripts, do not touch TypeScript
  inventory.

### 2. "Embedded grammars" are not truly embedded yet

`src/chiasmus/graph/embedded_grammars.cr` still falls back to runtime reads from
the repo grammar directories. `get_compile_time_embedded_grammar` currently
returns `nil`.

Impact:

- "standalone" packaging is weaker than the name suggests
- artifact portability depends on the packaging step copying dynamic grammar
  files correctly
- local dev may work while release artifacts remain incomplete

Parity handling:

- Treat this as a Crystal-native divergence unless/until upstream introduces
  equivalent embedded-delivery behavior.

### 3. Packaging still assumes macOS conventions in places

The local `Makefile dist` target is still not platform-neutral:

- copies grammar libraries with `ext=dylib`
- emits a `.tar.gz` unconditionally
- copies binaries without applying `Platform.executable_extension`
- assumes Unix-style names for packaged executables

Impact:

- local `make dist` is not a trustworthy rehearsal for Linux/Windows packaging
- release workflow and local packaging can diverge

Parity handling:

- Crystal-native. No TypeScript inventory edits.

### 4. Wrapper scripts lag behind the main grammar pipeline

These wrapper scripts still use the older 10-language set:

- `scripts/setup_grammars_new.cr`
- `scripts/download_grammars_new.cr`
- `scripts/build_static.cr`
- `src/chiasmus/graph/embedded_grammars.cr`

The main installer/compiler script already knows about a larger set:

- `scripts/setup_grammars.cr`

Impact:

- different entry points build different grammar inventories
- docs and CI can claim support that release artifacts do not actually include

Parity handling:

- Split runtime grammar availability from packaging grammar coverage.
- Update inventory only if runtime behavior exposed to users changes.

### 5. Windows build support exists, Windows test support does not

The repo already does Windows CLI builds in CI and release workflows. That is
meaningful progress, but it is not the same as Windows runtime confidence.

Current gap:

- no Windows spec job in the main test matrix

Additional nuance:

- solver/runtime dependencies such as Z3 and SWI-Prolog may remain optional on
  Windows
- grammar-dependent specs already use `pending` patterns in places when a
  grammar is unavailable, which is useful for gradual rollout

Impact:

- release artifacts may build successfully without proving runtime behavior on
  Windows

Parity handling:

- Crystal-native release/signoff hardening.
- Useful for parity confidence, but not an upstream ledger item by itself.

### 6. Release matrix is still incomplete

`release.yml` currently builds:

- Linux x86_64
- macOS aarch64
- Windows x86_64

Missing from the old target matrix:

- macOS x86_64
- Linux aarch64

Also missing from the release artifact set:

- `chiasmus-facts`

Impact:

- release artifacts do not yet cover the intended install matrix
- locally-built tools and shipped tools are not the same set

Parity handling:

- Crystal-native release/signoff hardening.

## Execution Plan

The slices below are written to be usable as parity-skill work items. Each is a
branch-sized feature, not a vague theme.

### Phase 1: Remove platform drift in code and scripts

Goal: one source of truth for file naming and platform-specific extensions.

Required changes:

1. Replace local extension helpers with `Chiasmus::Platform`.
2. Update `src/chiasmus/discovery/grammar_loader.cr` to stop duplicating
   `shared_library_extension`.
3. Update `scripts/build_static.cr` to use platform helpers for:
   - library extension
   - executable suffix
   - artifact naming
4. Update `Makefile dist` to derive:
   - grammar extension
   - packaged executable names
   - archive format choice per platform

Acceptance criteria:

- no grammar or packaging code path hardcodes `dylib`, `so`, or `dll` except
  inside `src/chiasmus/platform.cr`
- local packaging on Windows no longer relies on Unix filename assumptions

Inventory impact:

- likely yes for `grammar_loader.cr`
- no for `Makefile`/packaging-only fixes

Recommended checks:

```bash
make format
make lint
make test
```

### Phase 2: Unify the grammar inventory

Goal: every supported entry point talks about the same language set.

Canonical source should be the grammar inventory already represented by:

- `scripts/setup_grammars.cr`

Required changes:

1. Define one canonical grammar list in a shared place.
2. Make these consumers read from that shared list:
   - `scripts/setup_grammars_new.cr`
   - `scripts/download_grammars_new.cr`
   - `scripts/build_static.cr`
   - `src/chiasmus/graph/embedded_grammars.cr`
3. Decide whether `chiasmus-facts` and packaged artifacts should ship:
   - all supported grammars
   - or a documented "core grammar set"

Acceptance criteria:

- one language inventory drives setup, packaging, and embedding
- no wrapper script silently drops grammars supported by the main pipeline

Inventory impact:

- yes if runtime grammar availability changes
- no if this is only packaging/build-script alignment

Recommended checks:

```bash
make format
make lint
make test
```

### Phase 3: Make "embedded grammars" honest

Goal: either truly embed grammars at build time, or rename/document the current
behavior as extraction from packaged shared libraries.

Two acceptable directions:

- **True embedding**
  generate compile-time embedded blobs and extract them at runtime
- **Explicit packaged-dynamic model**
  stop implying compile-time embedding and treat grammar `.so/.dylib/.dll`
  files as required packaged assets

Recommendation:

- pick the explicit packaged-dynamic model first, because it matches the current
  release workflow and is lower risk
- only add true compile-time embedding if standalone single-file delivery is a
  real product requirement

Acceptance criteria:

- the code, docs, and release story all describe the same runtime model

Inventory impact:

- usually no
- only yes if runtime lookup/extraction semantics for tracked upstream behavior
  change

### Phase 4: Expand CI from build confidence to runtime confidence

Goal: test what we ship, not just compile it.

Required changes:

1. Keep the existing macOS/Linux test matrix.
2. Add a Windows spec job for the subset that is expected to work there now.
3. Split Windows CI into explicit layers:
   - core/unit tests
   - grammar-dependent tests
   - optional solver integration tests
4. Use skip/tag policy for platform-limited dependencies instead of pretending
   the full Unix matrix is portable as-is.

Suggested Windows-first command split:

- `crystal spec spec/chiasmus/utils spec/scripts`
- selected discovery/graph specs after grammar compilation succeeds
- solver specs only where dependencies are available

Acceptance criteria:

- Windows CI runs at least a meaningful green subset of specs
- unsupported dependency cases are explicit and documented

Inventory impact:

- no

Recommended checks:

- validate the workflow files
- run the closest local spec subset you changed
- keep full repo gates green on the primary dev platform

### Phase 5: Align release artifacts with the actual product surface

Goal: make release assets reflect what the repo builds and documents.

Required changes:

1. Decide the supported release binary set:
   - minimum: `chiasmus`, `chiasmus-discover`, `chiasmus-grammar`,
     `chiasmus-parity`
   - optional: `chiasmus-facts`
2. Extend the release matrix to the intended architectures:
   - Linux x86_64
   - Linux aarch64
   - macOS aarch64
   - macOS x86_64
   - Windows x86_64
3. Normalize archive naming using platform helpers, not raw `runner.os`.
4. Package grammar assets using the same canonical grammar list from Phase 2.

Acceptance criteria:

- release artifacts are architecture-complete for the supported matrix
- local packaging and CI release packaging produce the same binary set

Inventory impact:

- no

## Recommended Order

Do the work in this order:

1. Phase 1: remove hardcoded platform drift
2. Phase 2: unify grammar inventory
3. Phase 5: align release artifacts
4. Phase 4: add Windows runtime CI
5. Phase 3: decide whether true embedding is still worth doing

Reasoning:

- packaging and workflow drift is the current source of false confidence
- Windows runtime testing is useful only after naming and packaging conventions
  stop changing under it
- true binary embedding is more of a product choice than a prerequisite for
  cross-platform correctness

## Feature Templates For The Skill

When pulling work from this document into `plans/parity.md`, use slices shaped
like these:

- `PX Platform Runtime Loader Convergence`
  Source of truth: `src/chiasmus/platform.cr`, `src/chiasmus/discovery/grammar_loader.cr`
  Inventory: yes if upstream-backed runtime behavior changes.

- `PX Grammar Inventory Unification`
  Source of truth: grammar list used by setup/runtime/packaging.
  Inventory: only for runtime-visible behavior changes.

- `PX Windows Runtime Confidence`
  Source of truth: CI workflow + spec subset.
  Inventory: no.

- `PX Release Artifact Matrix Alignment`
  Source of truth: `Makefile`, `release.yml`, shipped binary set.
  Inventory: no.

- `PX Embedded Grammar Delivery Model`
  Source of truth: `embedded_grammars.cr`, packaging docs, release behavior.
  Inventory: usually no.

## Concrete Follow-Up Tasks

### High priority

- Replace duplicated extension helpers in `grammar_loader.cr`.
- Remove `dylib` hardcoding from `Makefile dist`.
- Convert wrapper scripts to the same grammar inventory used by
  `scripts/setup_grammars.cr`.
- Decide whether `chiasmus-facts` is a release artifact or local-only tool.

### Medium priority

- Add Windows subset spec coverage to `ci.yml`.
- Add missing Linux/macOS architecture targets to `release.yml`.
- Normalize archive naming and executable suffix handling in release packaging.

### Low priority

- Implement true compile-time grammar embedding if single-archive delivery is
  required.

## Verification Recipes

### For vendor-backed runtime changes

Run:

```bash
SKILL_DIR="${CHIASMUS_PARITY_SKILL_DIR:-$HOME/.agents/skills/crystal_forge/skills/cross-language-crystal-parity}"

make format
make lint
make test
"${SKILL_DIR}/scripts/check_port_inventory.sh" . plans/inventory/typescript_port_inventory.tsv vendor/chiasmus typescript
"${SKILL_DIR}/scripts/check_source_parity.sh" . plans/inventory/typescript_source_parity.tsv vendor/chiasmus typescript
"${SKILL_DIR}/scripts/check_test_parity.sh" . plans/inventory/typescript_test_parity.tsv vendor/chiasmus typescript
```

Use `check_completion_gate.sh` when the change affects fact-driven
completeness, reachable vendor coverage, or structural signoff:

```bash
"${SKILL_DIR}/scripts/check_completion_gate.sh" . plans/inventory/typescript_port_inventory.tsv vendor/chiasmus typescript src
```

Use `verify_parity_adversarial.sh` when the change materially affects parity
signoff or tool exposure; it now includes the completion gate.

### For Crystal-native release/CI/packaging changes

Run the narrowest useful checks plus repo gates:

```bash
make format
make lint
make test
```

Then verify the changed workflow directly, for example:

- build the affected CLI locally
- run the relevant packaging target
- inspect the workflow matrix and artifact set

Do not claim vendor inventory movement for these changes.

## Intentional Divergence Policy

Cross-platform delivery in this repo includes legitimate Crystal-native behavior
that upstream TypeScript does not model:

- GitHub Actions matrix design
- archive naming and packaging format
- which CLIs this port ships as standalone tools
- whether grammars are embedded vs packaged as separate shared libraries

Record those as intentional Crystal-native design choices in docs and release
notes. Do not force them into the TypeScript parity ledger just to make the
skill "see" them.

## Definition of Done

Cross-platform support is "done" for this repo only when all of the following
are true:

- runtime library naming comes from one platform module
- grammar inventory is shared across setup, compile, embed, and packaging
- local `make dist` is platform-neutral
- CI executes a real Windows spec subset, not just Windows builds
- release artifacts cover the intended OS/arch matrix
- docs describe the current delivery model honestly
- any vendor-backed runtime changes have clean parity drift checks
