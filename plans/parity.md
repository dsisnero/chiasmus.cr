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
- **MCP tools** — `chiasmus_verify`, `chiasmus_formalize`, `chiasmus_solve`, `chiasmus_skills`, `chiasmus_lint`, `chiasmus_craft`, `chiasmus_learn` all have direct Crystal tool specs covering response shape, error handling, end-to-end flows, and most behavior cases. Verified: Prolog explain-trace, Z3 sat verification, Prolog query verification, solver-type filter, exact-name lookup, related-templates, all-templates listing.
- **MCP `handleSkills`** source ported.
- **Mermaid support** — all source and test coverage complete.
- **Solver core** — basic solver ports and specs exist (inferred from downstream formalize and craft solver tests).

### Still missing in major ways:

- **MCP tool listing** — tool listing for formalize/verify/skills/solve, created template appears in skills search still unported.
- **Clojure graph support** — all `graph/clojure.test.ts` rows missing (extractor, parser, ns/defn/calls, multi-file, dead code). Corresponding source extractor functions all missing.
- **Graph extractor (JS/TS/Python/Go)** — all `extractor.test.ts` rows missing. Source-level `walkNode`, `walkPython`, `walkGo`, resolve functions all missing. Only adapter-based extraction is tested.
- **Dynamic adapter discovery** — `registerFromModule`, `isLanguageAdapter` still missing. Explicit-registration only.
- **Solver session isolation** — all `session.test.ts` rows missing. `SolverSession` class and `session.ts` source unported.
- **Prolog solver** — all `prolog-solver.test.ts` rows missing. Functions (`createPrologSolver`, `consult`, `query`, `nextAnswer`, tracing) unported.
- **Z3 solver** — all `z3-solver.test.ts` rows missing. Functions (`getZ3`, `sanitizeSmtlib`) and constants (`SOLVER_TIMEOUT_MS`) unported.
- **Correction loop** — all correction-loop source types and tests missing.
- **Benchmark suites** — all benchmark source interfaces and test rows missing.
- **Dogfood suites** — all `dogfood.test.ts` rows missing.
- **Graph MCP integration** — all `graph/mcp-integration.test.ts` rows missing.
- **LLM adapters** — `AnthropicAdapter`, `OpenAICompatibleAdapter`, `MockLLMAdapter` missing (intentional divergence — Crig replaces vendor adapters).
- **BM25 search** — all `bm25.ts` source functions and types missing.
- **Skills low-level types** — `SkillExtractResult`, `SkillExtraction`, `ExtractionResult` types may still have gaps.
- **MCP server constants** — `VALID_ANALYSES` still missing.
- **Prolog solver constants** — `MAX_ANSWERS`, `MAX_INFERENCES`, `MAX_TRACE_ENTRIES` missing.
- **Inventory cleanup** — `typescript_source_parity.tsv` still has stale `missing` for ported graph/analyses.ts, graph/facts.ts, graph/types.ts, graph/parser.ts, skills/types.ts.

## Major Gap Areas

### 1. MCP Server Breadth

The repo has several direct tool specs. The bulk of MCP behavior is now ported.

**Remaining gaps (6 rows in `mcp-server.test.ts`):**
- `[ ]` tool listing — `lists chiasmus_formalize in available tools`
- `[ ]` tool listing — `lists chiasmus_skills in available tools`
- `[ ]` tool listing — `lists chiasmus_solve in available tools`
- `[ ]` tool listing — `lists chiasmus_verify in available tools`
- `[ ]` tool listing — `appears in tool list` (craft tool)
- `[ ]` created template appears in chiasmus_skills search

**Completed (13 rows in `mcp-server.test.ts`):**
- `[x]` chiasmus_verify overall describe block
- `[x]` verifies satisfiable Z3 SMT-LIB input
- `[x]` verifies unsatisfiable Z3 input
- `[x]` verifies Prolog queries
- `[x]` returns structured error for malformed Z3 input
- `[x]` returns structured error for malformed Prolog input
- `[x]` includes unsatCore in unsat Z3 response
- `[x]` returns trace when explain=true for Prolog
- `[x]` requires query parameter for prolog solver
- `[x]` chiasmus_verify batch queries (partial — Crystal returns error vs upstream success)
- `[x]` runs multiple Prolog queries (partial — same behavior difference)
- `[x]` lists chiasmus_lint in available tools
- `[x]` searches for templates by query

Why this matters:

- MCP is the user-facing API surface
- parity here catches response-shape drift quickly

Work:

1. `[x]` ~~Port remaining verify tool parity~~ (5 new test rows ported)
2. `[ ]` Port remaining tool listing and skills-search rows
3. `[ ]` Decide whether to add a lightweight Crystal in-memory MCP harness later

Acceptance:

- major MCP behaviors are covered via direct tool specs even if transport-layer MCP harness is deferred
- `[x]` no contradictory duplicate rows remain in inventory manifests

### 2. MCP chiasmus_verify Tool Gap — Completed

- `[x]` All upstream `chiasmus_verify` test behaviors ported (10 of 11 rows, 1 partial)
- `[x]` Verify output shape matches upstream expectations (JSON with status/model/error/answers/unsat_core/trace)
- `[x]` Subsumed into section 1 (MCP Server Breadth) — no separate tracking needed

### 3. Clojure Graph Support

**Status:** All missing (9 `graph/clojure.test.ts` rows, 1 source file)

Why this matters:

- clearest language-support gap left in tree-sitter parity
- upstream has dedicated behavior around namespaces, imports, private/public defs

Work:

1. `[ ]` Add `.clj` language mapping and parser support
2. `[ ]` Port Clojure extraction: `ns` requires/imports, `defn`/`defn-`, namespace-qualified call normalization
3. `[ ]` Port multi-file cross-namespace extraction, deduplication, and Prolog facts
4. `[ ]` Backfill direct Clojure graph specs before structural refactors

### 4. Graph Extractor — Language Walkers (JS/TS/Python/Go)

**Status:** All missing (18 `extractor.test.ts` rows, 1 source file)

Why this matters:

- extractor is the foundation of all graph analysis
- adapter-based extraction is tested, but direct tree-sitter walker functions are not ported
- upstream has detailed behavior around method calls, exports, imports, classes, receivers

Work:

1. `[ ]` Audit current Crystal adapter-based extraction against upstream tree-sitter walker behavior
2. `[ ]` Port `walkNode`, `walkChildren`, `resolveCallee` (JS/TS walker core)
3. `[ ]` Port `walkPython`, `walkPythonChildren`, `findPythonEnclosingClass`, `resolvePythonCallee`
4. `[ ]` Port `walkGo`, `extractGoCalls`, `extractGoReceiverType`, `resolveGoCallee`
5. `[ ]` Port `extractImportNames`, `extractStringContent`, `findEnclosingClassName`
6. `[ ]` Add direct Crystal extractor specs for each walker

### 5. Solver Session Isolation And Concurrency

**Status:** All missing (5 `session.test.ts` rows, 1 source file)

Why this matters:

- project explicitly depends on concurrency correctness
- session isolation affects real solver safety

Work:

1. `[ ]` Audit current `Solvers::Session` against upstream expectations
2. `[ ]` Port specs for: unique session IDs, isolated Z3 sessions, isolated Prolog sessions, concurrent mixed-solver operation
3. `[ ]` Fix concurrency or shared-state leaks uncovered by specs

### 6. Prolog Solver

Why this matters: used throughout formalize, craft, and solve paths.

Work:
1. `[ ]` Port `createPrologSolver`, `consult`, `query`, `nextAnswer`, `entry`, `links` functions
2. `[ ]` Add specs for fact queries, recursive rules, arithmetic, list operations, ground queries, tracing, malformed input errors

### 7. Z3 Solver

Why this matters: used throughout formalize and solve paths.

Work:
1. `[ ]` Port `getZ3`, `sanitizeSmtlib`, `SOLVER_TIMEOUT_MS`
2. `[ ]` Add specs for boolean satisfiability, contradictory constraints, unsat core (named/unnamed), model for SAT, malformed input, empty input, custom datatypes

### 8. Correction Loop

Why this matters: used by formalize engine for fix-retry behavior; indirectly covered but no direct specs.

Work:
1. `[ ]` Port `CorrectionLoopOptions`, `CorrectionAttempt`, `CorrectionResult`, `SpecFixer` types
2. `[ ]` Add direct specs for correction-loop behavior

### 9. Benchmark And Dogfood Suites

Why this matters: high-signal integration regressions; validate real usefulness beyond unit-level parity.

Work:
1. `[ ]` Port benchmark fixtures incrementally, one problem at a time
2. `[ ]` Port dogfood scenarios that exercise realistic domains
3. `[ ]` Treat as end-to-end parity signoff, not early bootstrap

### 10. Graph MCP Integration

Why this matters: graph analyses are ported but graph MCP wire-up and integration tests are missing.

Work:
1. `[ ]` Port graph MCP integration cases for callers, dead-code, summary, facts, missing parameters, tool listing

### 11. Dynamic Adapter Discovery

Intentionally deferred, but a source-level gap. Current Crystal explicit-registration only.

Work:
1. `[ ]` Define Crystal runtime discovery model
2. `[ ]` Decide medium: filesystem manifest, Crystal plugin registry, or explicit module descriptors
3. `[ ]` Port discovery semantics (idempotent, non-throwing)
4. `[ ]` Add tests for recursive search paths and invalid modules

### 12. LLM Compatibility Surface

Intentional divergence: Crig replaces upstream vendor adapters (Anthropic, OpenAI, Mock).

Work:
1. `[ ]` Mark all LLM adapter rows with explicit "intentional divergence" notes in inventory manifests

## Recommended Execution Order

### Phase 1: Complete MCP Tool Surface

- `[x]` MCP `chiasmus_verify` deep parity (all verify test rows ported)
- `[ ]` Remaining MCP tool listing (formalize/verify/skills/solve, created template in skills search)
- `[ ]` Graph MCP integration
- `[x]` Reconcile duplicate inventory rows

### Phase 2: Solver Completeness

- `[ ]` Prolog solver
- `[ ]` Z3 solver
- `[ ]` Correction loop
- `[ ]` Session isolation/concurrency

### Phase 3: Graph Feature Parity

- `[ ]` Graph extractor walkers (JS/TS/Python/Go)
- `[ ]` Clojure graph support

### Phase 4: End-To-End Confidence

- `[ ]` Dogfood scenarios
- `[ ]` Benchmark suites

### Phase 5: Deferred Architectural Gaps

- `[ ]` Dynamic adapter discovery
- `[ ]` LLM compatibility divergence notes
- `[ ]` BM25 search
- `[ ]` Inventory hygiene — `typescript_source_parity.tsv` stale `missing` rows for ported graph files

## Inventory Cleanup

### Done

1. **Duplicate MCP rows reconciled** — Removed 12 duplicate rows (495-506) from `port_inventory.tsv` with imprecise glob references. Corrected 8 stale statuses (2 → `partial`, 5 → `ported`, 1 → `missing`).
2. **test_parity.tsv corrected** — 11 status changes matching port_inventory updates (solver-type filter, exact-name lookup, related-templates, all-templates, suggestions, explain-trace → `ported`).

### Remaining

- `typescript_source_parity.tsv` has stale `missing` rows for graph/analyses.ts, graph/facts.ts, graph/types.rs, graph/parser.ts, skills/types.ts — all actually ported
- Intentional divergences need explicit notes: Crig replacing upstream LLM adapters

## Completion Criteria

1. `[ ]` Major missing suites above are either ported or explicitly marked as intentional divergence
2. `[x]` `crystal spec` remains green
3. `[x]` `./bin/ameba src spec` remains green
4. `[ ]` No stale high-signal missing rows for already-ported areas in inventory manifests
5. `[ ]` MCP tool behavior matches upstream expectations for the core verification workflow
6. `[ ]` Graph and session behavior covered by dedicated parity specs, not only indirect integration tests
7. `[x]` No contradictory duplicate rows remain in any inventory file
