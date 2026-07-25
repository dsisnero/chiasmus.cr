# Logos parity workflow resolution

## Goal

Make the canonical `cross-language-crystal-parity` skill reliably usable from
`/Volumes/extreme_ssd/repos/github.com/dsisnero/logos`, with an auditable
Chiasmus/tree-sitter discovery path for the `logos_rust` workspace.

## Acceptance criteria

1. The installed skill runs canonical, executable wrappers (no copied script
   snapshot).
2. Explicit `--parser tree-sitter` either runs `chiasmus-discover` or fails;
   it must never emit a regex manifest as success.
3. Every generated manifest records the effective backend, binary path/version
   where applicable, and declared source scope.
4. The workflow accepts an explicit scope: whole workspace, selected roots, and
   exclusions. The Logos invocation records its chosen scope.
5. A release/skill bundle provides the Rust grammar required by the host
   platform, with no compiler/network dependency during discovery.
6. A clean Logos run completes through the top-level wrapper in strict
   tree-sitter mode and validates the generated manifests.

## Work items

- [x] Audit the actual Logos source layout and choose the intended inventory
  scope; do not infer library-only scope from a workspace root.
- [x] Add scope arguments and manifest metadata to the canonical parity scripts
  (roots and exclusions), preserving current defaults.
- [x] Add an installation preflight command that verifies executable wrappers,
  chosen discovery binary, backend availability, and requested language parser.
- [x] Make the top-level workflow invoke preflight and print a concise
  machine-readable resolution report before writing manifests.
- [x] Exercise the complete strict workflow against Logos in a clean temporary
  output location; compare reported backend and scope with the requested values.
- [x] Run manifest validation and document exact commands/output as verification
  evidence here.

## Completion evidence

The existing `darwin-aarch64` discovery bundle already contains a functioning
Rust grammar, as demonstrated by the strict run below. A parser pack remains a
release portability enhancement, not a blocker for the currently supported
bundle. The skill must ship equivalent grammar-bearing bundles for each
advertised platform.

## Verification (2026-07-24)

Executed the canonical wrapper in an empty temporary root; the Logos checkout
was read only:

```bash
SKILL=/Users/dominic/.agents/skills/crystal_forge/skills/cross-language-crystal-parity
"$SKILL/scripts/ensure_parity_plan.sh" "$TMP" \
  /Volumes/extreme_ssd/repos/github.com/dsisnero/logos/logos_rust \
  rust tree-sitter 0 'src,logos-derive/src,tests' \
  'examples/**,fuzz/**,logos-cli/**,logos-codegen/**'
```

Results:

- `PARITY_SKILL_VERIFIED=1`
- `PARITY_DISCOVERY_BACKEND=chiasmus-tree-sitter` for generation and all checks
- 59 scoped source/inventory items and 14 scoped test items
- port-inventory, source-parity, and test-parity checks all passed
- each manifest recorded backend, binary command, include roots, and exclusions
  in its `.metadata.json` sibling.
