# Remaining Parity Plan

## Goal

Finish the remaining high-value TypeScript-to-Crystal parity work in a way that keeps:

- upstream behavior as the source of truth
- `crystal spec` green throughout
- `./bin/ameba src spec` green throughout
- `plans/inventory/*` aligned with the real state of the port

This plan focuses on the major unresolved parity gaps that still materially affect behavior, coverage, or user-facing workflows.

## Current State

### What is now in good shape (ported in inventory):

- **Validation and linting** — `lintSpec`, `lintSmtlib`, `lintProlog`, `LintResult` all ported; all `validate.test.ts` rows ported; MCP `chiasmus_lint` tool wired with direct specs.
- **Craft template flow** — `validateTemplate`, `buildPrologInput`, `CraftInput`, `CraftResult` all ported; all `craft.test.ts` rows ported; MCP craft tool with validation and solver testing covered.
- **Formalize solve-path depth** — all `formalize.test.ts` rows ported including correction-loop retry, enriched feedback coverage, template-use recording, Z3 and Prolog end-to-end solve.
- **Graph analyses** — all `analyses.ts` API surface ported; all `analyses.test.ts` analysis modes (callers, callees, reachability, dead-code, path, impact, cycles, summary, facts, error handling) covered.
- **Graph facts** — `BUILTIN_RULES`, `escapeAtom`, `graphToProlog` ported; all `facts.test.ts` rows ported.
- **Graph Mermaid** — all source functions and interface types ported; all test rows ported including flowchart, state diagram, solver integration, reachability.
- **Graph adapter-registry** — all core adapter operations ported; all `adapter-registry.test.ts` rows ported including discovery, precedence, deduplication, integration.
- **Graph parser** — parser surface ported; basic parser specs for extension mapping, supported extensions, unsupported extension behavior.
- **Graph types** — all fact types, `LanguageAdapter`, `SymbolKind` ported.
- **Config** — `loadConfig`, `ChiasmusConfig` ported; all `config.test.ts` rows ported including JSON fallback, unknown-key handling, adapterDiscovery key.
- **Feedback** — `classifyFeedback` and `core` ported; all `feedback.test.ts` rows ported.
- **Skills library** — `SkillLibrary`, `SearchOptions` ported; all `skill-library.test.ts` rows ported including search, filter, metadata persistence, template structure.
- **Skills relationships** — `getRelatedTemplates`, `RelatedTemplate` ported; all `relationships.test.ts` rows ported.
- **Skills learner** — `SkillLearner` and all constants ported; all `learning.test.ts` rows ported including extraction, dedup, promotion, validation.
- **Skills types** — all `SkillTemplate`, `SlotDef`, `Normalization`, `SkillMetadata`, `SkillSearchResult`, `SkillWithMetadata` ported.
- **MCP tools** — `chiasmus_verify`, `chiasmus_formalize`, `chiasmus_solve`, `chiasmus_skills`, `chiasmus_lint`, `chiasmus_craft` all have direct Crystal tool specs covering tool listing, response shape, error handling, and end-to-end flows.
- **MCP `handleSkills`** source ported.
- **Mermaid support** — all source and test coverage complete.
- **Solver core** — basic solver ports and specs exist (inferred from downstream formalize and craft solver tests).

### Still missing in major ways:

- **Broad MCP server parity** — several `mcp-server.test.ts` rows remain missing (verify Prolog/Z3 queries, trace with explain=true, multiple Prolog queries, structured error for malformed input, solver type filtering, tool listing for formalize/skills/solve/verify). Some rows have duplicate `missing` and `ported` entries in the combined port_inventory that need reconciliation.
- **MCP `chiasmus_verify`** tool spec — basic tests exist but upstream `verify` test rows remain unported (Prolog query verification, satisfiable Z3, unsatisfiable Z3, batch queries).
- **Clojure graph support** — all `graph/clojure.test.ts` rows still missing (extractor, parser, ns/defn/calls, multi-file, dead code). Corresponding source extractor functions all missing.
- **Graph extractor (JS/TS/Python/Go)** — all `extractor.test.ts` rows still missing. Source-level `walkNode`, `walkPython`, `walkGo`, resolve functions all missing. Only adapter-based extraction is tested.
- **Dynamic adapter discovery** — `registerFromModule`, `isLanguageAdapter` still missing. Discovery is explicit-registration only.
- **Solver session isolation** — `session.test.ts` all rows missing. `SolverSession` class and `session.ts` source unported.
- **Prolog solver** — all `prolog-solver.test.ts` rows missing. Prolog solver functions (`createPrologSolver`, `consult`, `query`, `nextAnswer`, tracing) unported.
- **Z3 solver** — all `z3-solver.test.ts` rows missing. Z3 solver functions (`getZ3`, `sanitizeSmtlib`) and constants (`SOLVER_TIMEOUT_MS`) unported.
- **Correction loop** — all `correction-loop.test.ts` rows missing. Source correction-loop types and interface unported.
- **Benchmark suites** — all benchmark source interfaces and test rows missing.
- **Dogfood suites** — all `dogfood.test.ts` rows missing.
- **Graph MCP integration** — all `graph/mcp-integration.test.ts` rows missing.
- **LLM adapters** — `AnthropicAdapter`, `OpenAICompatibleAdapter`, `MockLLMAdapter`, `LLMAdapter` interface, `LLMMessage` all missing (intentional divergence — Crig replaces vendor adapters).
- **BM25 search** — all `bm25.ts` source functions and types missing.
- **Skills low-level types** — some `skills/types.ts` interfaces now ported (see above), but `SkillExtractResult`, `SkillExtraction`, `ExtractionResult` types may still have gaps.
- **MCP server constants** — `VALID_ANALYSES` still missing. `TOOLS` const ported implicitly via individual tool registrations.
- **Prolog solver constants** — `MAX_ANSWERS`, `MAX_INFERENCES`, `MAX_TRACE_ENTRIES` missing.
- **Inventory cleanup** — stale duplicate rows in port_inventory.tsv where the same test is listed as both `missing` (rows 216-251, 389-416) and `ported` (rows 495-506) with different spec refs.

## Major Gap Areas

### 1. MCP Server Breadth

The repo has several direct tool specs, but the upstream MCP test surface is still only partially covered:

- many rows in `tests/mcp-server.test.ts` remain missing
- some rows are duplicated in the combined inventory as both missing and ported summaries

Why this matters:

- MCP is the user-facing API surface
- parity here catches response-shape drift quickly

Work:

1. Continue direct tool-level parity specs for missing cases:
   - `verify` malformed inputs, trace behavior, query requirements
   - `skills` search/list/by-name/error cases (most covered, verify/filter missing)
   - `formalize` missing-problem and suggestion behavior (most covered)
   - `solve` end-to-end and fallback behavior (most covered)
   - `lint` parity (completed — already ported)
   - `craft` parity (completed — already ported)
2. Decide whether to add a lightweight Crystal in-memory MCP harness later.
3. Reconcile duplicate inventory rows so tool parity status is not contradictory.

Acceptance:

- major MCP behaviors are covered via direct tool specs even if transport-layer MCP harness is deferred
- stale duplicate missing rows are removed or reconciled in manifests

### 2. MCP chiasmus_verify Tool Gap

The MCP verify tool has basic specs but upstream `verify` test cases are still underported:

- `tests/mcp-server.test.ts` rows for `chiasmus_verify` overall, batch queries, tool listing
- Prolog query verification, satisfiable/unsatisfiable Z3 verification

Why this matters:

- verify is a core user-facing workflow
- missing test parity leaves response-shape drift undetected

Work:

1. Port missing `chiasmus_verify` test cases from upstream MCP tests.
2. Ensure verify output shape matches upstream expectations.
3. These are a subset of the broader MCP gap — treat as part of that work.

Acceptance:

- all upstream verify-related MCP test behaviors are represented in Crystal specs

### 3. Clojure Graph Support

Still a major missing feature block:

- `vendor/chiasmus/tests/graph/clojure.test.ts`
- corresponding source support in extractor/parser language handling

Why this matters:

- this is the clearest language-support gap left in tree-sitter parity
- upstream has dedicated behavior around namespaces, imports, and private/public defs

Work:

1. Add `.clj` language mapping and parser support.
2. Port Clojure extraction behavior:
   - `ns` requires/imports
   - `defn` and `defn-`
   - namespace-qualified call normalization
   - multi-file cross-namespace extraction
   - deduplication and Prolog facts
3. Backfill direct Clojure graph specs before structural refactors.

Acceptance:

- `graph/clojure.test.ts` major rows are ported
- Clojure files participate in graph extraction and analysis

### 4. Graph Extractor (JS/TS/Python/Go)

Large unresolved extraction tranche:

- `vendor/chiasmus/src/graph/extractor.ts` — walk functions for JS, Python, Go, Clojure
- `vendor/chiasmus/tests/graph/extractor.test.ts`

Why this matters:

- extractor is the foundation of all graph analysis
- adapter-based extraction is tested, but direct tree-sitter walker functions are not ported
- upstream has detailed behavior around method calls, exports, imports, classes, receivers

Work:

1. Audit current Crystal adapter-based extraction against upstream tree-sitter walker behavior.
2. Port missing extractor functions:
   - `walkNode`, `walkChildren`, `resolveCallee`
   - `walkPython`, `walkPythonChildren`, `findPythonEnclosingClass`, `resolvePythonCallee`
   - `walkGo`, `extractGoCalls`, `extractGoReceiverType`, `resolveGoCallee`
   - `extractImportNames`, `extractStringContent`, `findEnclosingClassName`
3. Add direct Crystal extractor specs for each walker.

Acceptance:

- `extractor.test.ts` major behaviors are covered in Crystal
- extracted facts match upstream structure for JS, Python, Go sources

### 5. Solver Session Isolation And Concurrency

Still largely missing:

- `vendor/chiasmus/src/solvers/session.ts`
- `vendor/chiasmus/tests/session.test.ts`

Why this matters:

- the project explicitly depends on concurrency correctness
- session isolation affects real solver safety

Work:

1. Audit the current `Solvers::Session` against upstream expectations.
2. Add specs for:
   - unique session IDs
   - isolated Z3 sessions
   - isolated Prolog sessions
   - concurrent mixed-solver operation
3. Fix concurrency or shared-state leaks uncovered by the specs.

Acceptance:

- session test equivalents exist and are stable
- no shared-session contamination under concurrent specs

### 6. Prolog Solver

- `vendor/chiasmus/src/solvers/prolog-solver.ts`
- `vendor/chiasmus/tests/prolog-solver.test.ts`

Why this matters:

- Prolog solver is used throughout formalize, craft, and solve paths
- tests for query, consult, answers, tracing, structured errors are all unported

Work:

1. Port `createPrologSolver`, `consult`, `query`, `nextAnswer`, `entry`, `links` functions.
2. Add specs for fact queries, recursive rules, arithmetic, list operations, ground queries, tracing, malformed input errors.

Acceptance:

- `prolog-solver.test.ts` behaviors are represented in Crystal specs

### 7. Z3 Solver

- `vendor/chiasmus/src/solvers/z3-solver.ts`
- `vendor/chiasmus/tests/z3-solver.test.ts`

Why this matters:

- Z3 solver is used throughout formalize and solve paths
- tests for sat/unsat, unsat core, model, structured errors, custom datatypes are all unported

Work:

1. Port `getZ3`, `sanitizeSmtlib`, `SOLVER_TIMEOUT_MS`.
2. Add specs for boolean satisfiability, contradictory constraints, unsat core (named and unnamed), model for SAT, malformed input, empty input, custom datatypes.

Acceptance:

- `z3-solver.test.ts` behaviors are represented in Crystal specs

### 8. Correction Loop

- `vendor/chiasmus/src/solvers/correction-loop.ts`
- `vendor/chiasmus/tests/correction-loop.test.ts`

Why this matters:

- correction loop is used by formalize engine for fix-retry behavior
- formalize engine solve-path tests cover correction-loop indirectly, but direct loop specs are missing

Work:

1. Port `CorrectionLoopOptions`, `CorrectionAttempt`, `CorrectionResult`, `SpecFixer` types.
2. Add direct specs for correction-loop behavior.

Acceptance:

- `correction-loop.test.ts` behaviors are represented in Crystal specs

### 9. Benchmark And Dogfood Suites

Still unported:

- `vendor/chiasmus/benchmark/tests/*`
- `vendor/chiasmus/tests/dogfood.test.ts`

Why this matters:

- these are high-signal integration regressions
- they validate the real usefulness of the port beyond unit-level parity

Work:

1. Port benchmark fixtures incrementally, one problem at a time.
2. Port dogfood scenarios that exercise realistic domains.
3. Treat these as end-to-end parity signoff, not early bootstrap work.

Acceptance:

- benchmark and dogfood suites run as characterization parity checks
- failures map to actionable missing capabilities rather than harness issues

### 10. Graph MCP Integration

- `vendor/chiasmus/tests/graph/mcp-integration.test.ts`

Why this matters:

- graph MCP tool is a user-facing capability
- graph analyses are ported but graph MCP wire-up and integration tests are missing

Work:

1. Port graph MCP integration cases for callers, dead-code, summary, facts, missing parameters, tool listing.

Acceptance:

- graph MCP integration cases have Crystal equivalents

### 11. Dynamic Adapter Discovery

Still intentionally deferred, but still a major source-level gap:

- `vendor/chiasmus/src/graph/adapter-registry.ts` runtime discovery path (`registerFromModule`, `isLanguageAdapter`)
- current Crystal `discover_adapters` remains explicit-registration only

Why this matters:

- plugin-style language extension is still missing
- this is the last large adapter-registry parity hole

Work:

1. Define the Crystal runtime discovery model first.
2. Decide the supported discovery medium:
   - filesystem manifest
   - Crystal plugin registry
   - explicit module descriptors
3. Port discovery semantics and non-throwing/idempotent behavior.
4. Add equivalent tests for recursive search paths and invalid modules.

Acceptance:

- discovered adapters can be loaded without manual registration
- discovery remains idempotent and non-throwing

### 12. LLM Compatibility Surface

Still missing compared to upstream:

- `vendor/chiasmus/src/llm/anthropic.ts`
- `vendor/chiasmus/src/llm/openai-compatible.ts`
- `vendor/chiasmus/src/llm/mock.ts`
- `vendor/chiasmus/src/llm/types.ts` (`LLMAdapter`, `LLMMessage`)

Why this matters:

- local Crig integration is good, but upstream compatibility surface is still wider
- missing LLM rows will continue to show up in the manifests

Work:

1. Decide whether these rows should be treated as:
   - real missing parity
   - intentional architectural divergence because Crig replaces vendor adapters
2. For intentional divergence:
   - mark rows with explicit notes in the inventory
3. For retained behavior:
   - port the minimal needed compatibility wrapper and tests
4. Implement mock streaming if upstream behavior depends on it.

Acceptance:

- no ambiguous "missing" rows remain for LLM adapters without an explicit rationale

## Recommended Execution Order

### Phase 1: Complete MCP Tool Surface

1. MCP `chiasmus_verify` deep parity
2. Remaining MCP tool cases (explain=true, solver-type filter, tool listing, structured error for malformed input)
3. Graph MCP integration
4. Reconcile duplicate inventory rows

Reason:

- this closes the biggest user-visible parity gaps first
- fixes contradictory inventory state

### Phase 2: Solver Completeness

1. Prolog solver
2. Z3 solver
3. Correction loop
4. Session isolation/concurrency

Reason:

- solver layer is used by everything downstream
- formalize/craft/solve tests already exercise parts of this, but direct solver specs are missing

### Phase 3: Graph Feature Parity

1. Graph extractor (JS/TS/Python/Go walkers)
2. Clojure graph support

Reason:

- extractor foundation is partially present via adapter pattern
- remaining work is behavior completion of language-specific walkers

### Phase 4: End-To-End Confidence

1. Dogfood scenarios
2. Benchmark suites

Reason:

- these are better signoff gates after core functional parity is stable

### Phase 5: Deferred Architectural Gaps

1. Dynamic adapter discovery
2. LLM compatibility cleanup
3. BM25 search
4. Inventory hygiene and explicit divergence notes

Reason:

- these matter, but they are less blocking than the core verification flow

## Inventory Cleanup Tasks

The manifests currently contain contradictory or stale rows in a few areas. This needs to be treated as part of the parity work, not as optional cleanup.

Work:

1. Reconcile duplicate MCP rows where rows 389-416 are marked `missing` but rows 495-506 are marked `ported` with wildcard spec refs.
2. Reconcile `typescript_source_parity.tsv` rows for `graph/analyses.ts`, `graph/facts.ts`, `graph/types.ts`, `graph/parser.ts`, `skills/types.ts` — these are marked `missing` but are actually ported in Crystal.
3. Reconcile `typescript_test_parity.tsv` rows for `graph/analyses.test.ts`, `graph/facts.test.ts`, `graph/parser.test.ts`, `tests/mcp-server.test.ts` (chiasmus_verify, tool listing rows) — these are marked `missing` but have Crystal equivalents or partial coverage.
4. Add explicit notes for intentional divergences, especially around Crig replacing upstream LLM adapter architecture.

Acceptance:

- no row should be both effectively ported in code and still marked missing without explanation

## Completion Criteria

The remaining parity effort is complete when all of these are true:

1. Major missing suites above are either ported or explicitly marked as intentional divergence.
2. `crystal spec` remains green.
3. `./bin/ameba src spec` remains green.
4. `plans/inventory/typescript_port_inventory.tsv` has no stale high-signal missing rows for already-ported areas.
5. MCP tool behavior matches upstream expectations for the core verification workflow.
6. Graph and session behavior are covered by dedicated parity specs, not only by indirect integration tests.
7. No contradictory duplicate rows remain in any inventory file.
