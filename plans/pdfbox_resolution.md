# PDFBox parity-skill resolution

## Goal

Make the installed `cross-language-crystal-parity` skill run a reproducible,
strict Chiasmus/tree-sitter inventory for Apache PDFBox Java source without
modifying the PDFBox checkout.

## Acceptance criteria

1. The skill contains an executable `chiasmus-discover` for the host platform.
2. The bundled discovery path has the Java grammar it needs in a clean cache;
   strict discovery must not silently use regex or fetch/compile a grammar.
3. `--parser tree-sitter` reports and verifies Chiasmus/tree-sitter provenance.
4. PDFBox's intended scope is explicit and recorded with generated manifests.
5. An empty temporary target root can generate and validate inventory, source,
   and test manifests from `vendor/pdfbox`.

## Work items

- [x] Establish a clean-cache baseline for Java discovery and identify the
  required skill bundle contents.
- [x] Add/reuse strict discovery preflight, backend provenance, and scope
  metadata in this installed skill; do not maintain a second stale script copy.
- [x] Package the host `chiasmus-discover` binary and Java grammar alongside
  the skill, or wire a verified parser pack into discovery startup.
- [x] Run the top-level workflow in strict mode against PDFBox using a declared
  module scope and verify all manifests.

## Verification evidence

The named skill's `scripts/` directory now symlinks to the canonical Crystal
Forge parity scripts, avoiding a stale duplicate. The canonical `darwin-aarch64`
bundle contains `chiasmus-discover` and
`grammars/tree-sitter-java/libtree-sitter-java.dylib`; discovery finds the
sibling grammar before any cache/download path.

## Verification (2026-07-24)

Ran the named skill with `XDG_CACHE_HOME` set to a new temporary directory and
used a new temporary target root. The PDFBox checkout was read only:

```bash
SKILL=/Users/dominic/.agents/skills/cross-language-crystal-parity
"$SKILL/scripts/ensure_parity_plan.sh" "$TMP" \
  /Volumes/extreme_ssd/repos/github.com/dsisnero/pdfbox/vendor/pdfbox \
  java tree-sitter 0
```

Results:

- preflight identified the bundled discovery binary by SHA-256;
- all generation and check calls reported
  `PARITY_DISCOVERY_BACKEND=chiasmus-tree-sitter`;
- full PDFBox workspace scope (`.`) was recorded in manifest metadata;
- 9,990 source/inventory items and 1,806 test items were generated;
- port inventory, source parity, and test parity checks passed.
