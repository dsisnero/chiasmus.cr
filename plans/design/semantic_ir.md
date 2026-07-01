# Semantic IR For Graph And Parity Work

## Why

`chiasmus` currently lowers parser output into `CodeGraph` and then often
immediately lowers again into Prolog facts. That is good for graph queries, but
it means we lose language-specific structure early and then rebuild parts of it
later with side channels such as `FileTypeInfo`.

Examples of pressure from that design:

- parity matching needs owner-sensitive symbol identity
- structural parity wants normalized imports/calls/contains, not raw extracted
  fragments
- TypeScript/JavaScript call resolution needs extra type-environment state
- planning wants branch-sized semantic slices, not only flattened facts

## Design Goal

Add a semantic intermediate representation between extraction and facts:

```text
tree-sitter / walkers / adapters
  -> Semantic IR
  -> refiner passes
  -> CodeGraph
  -> Prolog facts / parity / planning / analyses
```

The point is not to replace `CodeGraph` or facts. The point is to delay the
loss of structure until after we have normalized it.

## What The IR Should Model

The IR should be richer than `CodeGraph`, but still much smaller than a full
AST.

Core entities:

- files
- symbols
- containment
- imports
- calls
- per-file type environment summaries

Important properties:

- stable symbol ids derived from file + kind + qualified name
- explicit owner/simple-name split for qualified symbols
- room for language metadata without infecting all downstream APIs
- immutable value objects so refinement stays testable and deterministic

## Why Not A Full Kiota-Style CodeDOM

Kiota's CodeDOM is generation-oriented: it models classes, methods, properties,
inheritance, and wrappers so language refiners can mutate the output model
before rendering source files.

This repo is analysis-oriented. Most downstream consumers want:

- stable semantic identity
- normalized relationship edges
- better structural comparisons
- better planning slices

So the right move is not "replace facts with CodeDOM". The right move is:

- keep facts as the query/export layer
- add a semantic IR above facts
- add ordered refiner passes that normalize language quirks before fact
  generation

## Refiner Model

Refiners should be ordered, pure-ish passes over the semantic IR. The first
implementation can stay immutable and return a new graph.

Likely pass families:

1. Common normalization
   - deduplicate duplicate symbol edges
   - normalize stable ids
   - repair owner/simple-name fields
2. TypeScript / JavaScript normalization
   - normalize constructors/getters/setters
   - normalize default exports and alias imports
   - move current `FileTypeInfo` hacks into first-class semantic data
3. Language-specific semantic enrichment
   - Crystal macro/lib/annotation shaping
   - Clojure form/module shaping
   - Java/C#/Go receiver and package normalization
4. Analysis-oriented refinement
   - mark likely entry points
   - attach export visibility
   - classify weak vs strong containment

## Initial Scope In Code

The initial implementation should stay intentionally small:

- `src/chiasmus/graph/ir.cr`
  - immutable semantic node/edge records
  - stable symbol id derivation
  - `CodeGraph` -> `SemanticGraph` lowering
  - `SemanticGraph` -> `CodeGraph` lowering
  - ordered refiner pipeline interface
  - async `refine_async` entrypoint using the repo-standard `Channel` + `spawn`
    pattern
- compatibility boundary updates
  - `Graph::Facts.graph_to_prolog` accepts either `CodeGraph` or
    `SemanticGraph`
  - `Graph::Analyses.run_analysis_from_graph` and async variants accept either
    `CodeGraph` or `SemanticGraph`
- `spec/chiasmus/graph/ir_spec.cr`
  - round-trip preservation tests
  - symbol id / owner extraction tests
  - refiner ordering tests
  - async pipeline coverage

That gives us a real abstraction in code without forcing a large extractor
rewrite immediately.

## Migration Plan

### Phase 1

Introduce the semantic IR as a compatibility layer above existing `CodeGraph`.
No extractor behavior changes yet.

Status now:

- complete for lowering/round-trip
- complete for ordered refiners
- complete for async refinement wiring
- complete for facts/analysis compatibility overloads
- not yet complete for extractor-emits-IR-first work

### Phase 2

Move `FileTypeInfo` and other side-channel semantic data into the IR as the
primary representation.

### Phase 3

Teach selected extractors/walkers to emit semantic nodes directly, then lower to
`CodeGraph` only at the compatibility boundary.

### Phase 4

Make parity/planning consume the refined semantic IR where it improves quality,
while still keeping facts for Prolog-based querying and signoff.

## Success Criteria

This layer is worth keeping if it measurably improves:

- parity match confidence
- structural drift signal quality
- planner slice quality
- amount of TS/JS-specific ad hoc resolution code outside the IR/refiner layer
