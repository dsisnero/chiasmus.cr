# Logos parity skill usage report: installed parity workflow falls back to regex and ships broken wrappers

## Resolution (2026-07-24)

Resolved for the supported `darwin-aarch64` skill bundle. The installed skill's
`scripts/` path now resolves to the canonical executable scripts, strict
`tree-sitter` discovery is preflighted and verified from its own TSV output, and
generated manifests have a sibling `.metadata.json` recording backend, binary,
and source scope.

The canonical strict run against Logos used `src,logos-derive/src,tests` and
excluded examples, fuzzing, CLI, and codegen paths. It produced 59 source items
and 14 test items; inventory, source, and test validation all passed using
`chiasmus-tree-sitter`. The same bundle must be supplied with a tested grammar
for each additional advertised platform before claiming equivalent portability.

## Summary

Using the newer `cross-language-crystal-parity` skill from the `logos` repo did
not exercise the intended Chiasmus-backed parity flow.

The immediate failure is a skill packaging/integration problem:

1. every shell wrapper in the installed skill is missing the executable bit
2. the installed skill does not include a bundled `chiasmus-discover` binary
3. `tree-sitter` mode silently degrades to regex discovery in this environment

Because of that, the workflow can still generate manifests by calling the Ruby
entrypoints directly, but it does not validate the newer Chiasmus discovery path
that the skill is supposed to enable.

This is not yet evidence of a core parser bug in Chiasmus. It is evidence that
the Chiasmus-powered parity workflow is not reliably consumable from a downstream
porting repo.

## Environment

- Date: July 24, 2026
- Host repo: `/Volumes/extreme_ssd/repos/github.com/dsisnero/logos`
- Skill install path:
  `/Users/dominic/.codex/skills/cross-language-crystal-parity`
- Upstream source under analysis: `logos_rust`

## What was attempted

The goal was to verify whether the newer parity inventory workflow, including
Chiasmus-backed discovery, could improve or refresh the parity inventory for the
`logos` Crystal port.

The intended entrypoint was:

```bash
/Users/dominic/.codex/skills/cross-language-crystal-parity/scripts/ensure_parity_plan.sh . logos_rust rust auto 1
```

## Actual behavior

### 1. Installed shell wrappers are not executable

Direct execution of the skill wrapper failed with `permission denied`.

Observed modes for installed wrappers:

```text
-rw-r--r-- /Users/dominic/.codex/skills/cross-language-crystal-parity/scripts/check_completion_gate.sh
-rw-r--r-- /Users/dominic/.codex/skills/cross-language-crystal-parity/scripts/check_port_inventory.sh
-rw-r--r-- /Users/dominic/.codex/skills/cross-language-crystal-parity/scripts/check_source_parity.sh
-rw-r--r-- /Users/dominic/.codex/skills/cross-language-crystal-parity/scripts/check_test_parity.sh
-rw-r--r-- /Users/dominic/.codex/skills/cross-language-crystal-parity/scripts/ensure_parity_plan.sh
-rw-r--r-- /Users/dominic/.codex/skills/cross-language-crystal-parity/scripts/generate_port_inventory.sh
-rw-r--r-- /Users/dominic/.codex/skills/cross-language-crystal-parity/scripts/generate_source_parity_manifest.sh
-rw-r--r-- /Users/dominic/.codex/skills/cross-language-crystal-parity/scripts/generate_test_parity_manifest.sh
-rw-r--r-- /Users/dominic/.codex/skills/cross-language-crystal-parity/scripts/plan_with_chiasmus.sh
...
```

Even forcing the top-level script through `bash` still failed because it invokes
non-executable sub-scripts directly:

```text
.../generate_source_parity_manifest.sh: Permission denied
```

### 2. No bundled Chiasmus discovery binaries were present

The installed skill did not contain `chiasmus-discover` or `chiasmus-parity`
release binaries under the skill directory, and the `logos` repo did not contain
a repo-local `bin/chiasmus-discover`.

That means the skill had no working binary-backed discovery path available in
this environment.

### 3. `tree-sitter` mode degraded to regex fallback

To continue the investigation, the Ruby entrypoints were invoked directly:

```bash
ruby /Users/dominic/.codex/skills/cross-language-crystal-parity/scripts/generate_source_parity_manifest.rb \
  --root . --source logos_rust --language rust --parser auto \
  --out temp/parity-skill-check/rust_source_parity.auto.tsv

ruby /Users/dominic/.codex/skills/cross-language-crystal-parity/scripts/generate_test_parity_manifest.rb \
  --root . --source logos_rust --language rust --parser auto \
  --out temp/parity-skill-check/rust_test_parity.auto.tsv

ruby /Users/dominic/.codex/skills/cross-language-crystal-parity/scripts/generate_port_inventory.rb \
  --root . --source logos_rust --language rust --parser auto \
  --out temp/parity-skill-check/rust_port_inventory.auto.tsv
```

Those commands succeeded, but explicit `tree-sitter` mode reported:

```text
tree-sitter parser unavailable for rust; falling back to regex
```

The generated source manifest in `auto`, `regex`, and explicit `tree-sitter`
modes was byte-identical. In other words, the environment never exercised a
Chiasmus/tree-sitter discovery path at all.

## Verified outputs

Direct Ruby generation produced internally consistent manifests:

- source parity manifest: 173 source items
- test parity manifest: 110 tests
- combined inventory: 283 items

The generated temp manifests also passed the skill’s own validation scripts when
the correct `--manifest` argument was supplied:

```text
Port inventory check passed (173 items tracked).
Test parity check passed (110 tests tracked).
```

This shows the Ruby manifest logic is functional in regex-fallback mode.

## Important scope observation

The generated inventory includes items from the whole Rust workspace, including:

- `logos-cli`
- `logos-codegen`
- examples
- test fixtures and test-only enums

Representative entries:

- `examples/brainfuck.rs::func::execute`
- `logos-cli/src/main.rs::func::main`
- `logos-codegen/src/error.rs::func::render`
- `logos-derive/src/lib.rs::func::logos`
- `src/lexer.rs::struct::Lexer`

This may be correct if the intended parity scope is “entire upstream workspace.”
It may be too broad if the intended parity scope is only the main runtime library
plus selected tests. The current behavior needs to be explicit.

This is not filed here as a parser bug. It is a usability/scoping issue in the
Chiasmus-backed parity workflow.

## Why this blocks Logos usage

For a downstream repo like `logos`, the current state means:

1. the documented parity wrapper cannot be executed as installed
2. the newer discovery path cannot be verified because no discovery binary is
   actually available
3. `tree-sitter` mode can appear to succeed while doing regex fallback instead
4. users cannot tell from normal workflow output whether they just refreshed the
   inventory with the new Chiasmus logic or with the legacy regex path

As a result, the new parity workflow is not trustworthy enough yet to replace or
refresh a real project’s parity inventory without manual investigation.

## What is needed from Chiasmus to correct it

### 1. Ship a usable parity skill bundle

The installed `cross-language-crystal-parity` skill must be installable in a
state that can actually run:

- all `scripts/*.sh` wrappers need executable permissions
- release packaging or install tooling must preserve those permissions
- the bundle should contain the expected discovery executables when the skill is
  advertised as Chiasmus-backed

If the intended model is “Ruby entrypoints only,” the shell wrappers should stop
calling sibling `.sh` scripts directly and should invoke `bash` explicitly or be
removed from the documented path.

### 2. Make discovery backend selection explicit and inspectable

The workflow currently degrades from `tree-sitter` to regex with only a warning
line. That is not strong enough for parity-authoring work.

Needed behavior:

- emit the chosen backend in a machine-readable way
- record whether discovery used `regex`, `tree-sitter`, or a Chiasmus binary
- expose the discovery binary path and version when relevant
- make `--parser tree-sitter` fail hard by default if Chiasmus/tree-sitter is
  unavailable, or provide a strict flag that does so

Without this, a user can believe they exercised the new logic when they did not.

### 3. Provide a first-class repo-scope model

The workflow needs a clear way to distinguish:

- whole-workspace inventory
- library-only inventory
- tests-only inventory
- curated include/exclude path sets

For `logos`, the difference matters because the upstream Rust workspace contains
CLI, codegen, examples, and test-only sources in addition to the main runtime.

Needed behavior:

- allow explicit include/exclude globs or path roots
- report the effective scope in generated manifests
- document what `source_path=logos_rust` means in a multi-crate workspace

### 4. Improve failure surfacing in the top-level workflow

`ensure_parity_plan.sh` should fail with a direct, actionable explanation when:

- wrappers are not executable
- required binaries are absent
- `tree-sitter` mode falls back
- generated manifests are broader than a previously checked-in scope

Right now too much diagnosis requires opening the skill internals manually.

### 5. Add an installation verification command for skill consumers

There should be a lightweight verification command for downstream repos that
asserts:

- wrappers are runnable
- required Ruby dependencies resolve
- Chiasmus discovery binaries are present if expected
- tree-sitter discovery works for the requested language
- the workflow can generate and validate a small sample manifest

This would catch broken skill bundles before users trust inventory output.

## Suggested acceptance criteria

The issue should be considered resolved when all of the following are true:

1. A fresh install of `cross-language-crystal-parity` has executable shell
   wrappers.
2. The installed skill either bundles a working `chiasmus-discover` path or
   clearly declares that only regex mode is available.
3. Running the top-level parity workflow in `logos` can definitively report
   whether it used Chiasmus/tree-sitter or regex fallback.
4. The workflow supports explicit scoping for multi-crate workspaces such as
   `logos_rust`.
5. A downstream maintainer can refresh inventory without inspecting the skill
   internals to determine whether the result is trustworthy.

## Non-goals / not yet proven

This report does not currently prove a semantic bug in Chiasmus parsing or symbol
extraction.

The verified problem today is that Chiasmus-backed parity is not packaged and
surfaced robustly enough for downstream use from `logos`.

If, after fixing the packaging and backend-selection issues above, the generated
inventory is still semantically wrong, that would justify a narrower follow-up
bug against Chiasmus discovery itself.
