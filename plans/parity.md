# Remaining Parity Plan

## Goal

Finish the remaining high-value TypeScript-to-Crystal parity work in a way that keeps:

- upstream behavior as the source of truth
- `crystal spec` green throughout
- `./bin/ameba src spec` green throughout
- `plans/inventory/*` aligned with the real state of the port

This plan focuses on the major unresolved parity gaps that still materially affect behavior, coverage, or user-facing workflows.

## Current State

Already in good shape:

- grammar management and metadata
- solver core port and basic solver specs
- learning core
- skill library starters and relationships
- adapter registry core, excluding dynamic discovery
- Mermaid support
- formalize template selection basics
- MCP tool slices for `verify`, `learn`, `skills`, `formalize`, and `solve`

Still missing in major ways:

- validation/lint parity
- craft parity
- deeper formalize solve-path parity
- broad MCP server parity
- graph analysis and graph MCP parity
- Clojure graph support parity
- session isolation/concurrency parity
- benchmark and dogfood parity suites
- dynamic adapter discovery
- richer LLM compatibility surface
- inventory cleanup for stale duplicate missing rows

## Major Gap Areas

### 1. Validation And Linting

Upstream source still missing or underrepresented locally:

- `vendor/chiasmus/src/formalize/validate.ts`
- `vendor/chiasmus/tests/validate.test.ts`
- MCP-facing lint behavior in `vendor/chiasmus/tests/mcp-server.test.ts`

Why this matters:

- linting is part of the correction-loop contract
- MCP `chiasmus_lint` parity is still incomplete
- several MCP tests depend on structured validation behavior

Work:

1. Port `lintSpec`, `lintSmtlib`, `lintProlog`, and `LintResult`.
2. Add direct Crystal specs for upstream validation cases.
3. Wire/verify `chiasmus_lint` output shape against upstream expectations.

Acceptance:

- upstream `validate.test.ts` behaviors are represented in Crystal specs
- MCP lint cases for bad Z3/Prolog input are covered
- inventory rows for `src/formalize/validate.ts` and `tests/validate.test.ts` are updated

### 2. Craft Template Flow

Upstream source still missing or only partially represented:

- `vendor/chiasmus/src/skills/craft.ts`
- `vendor/chiasmus/tests/craft.test.ts`
- MCP craft cases in `vendor/chiasmus/tests/mcp-server.test.ts`

Why this matters:

- `chiasmus_craft` is still not parity-complete
- template validation and creation are a core extensibility path
- craft and library behavior are tightly coupled

Work:

1. Port `validateTemplate` and `buildPrologInput` behavior faithfully.
2. Add direct craft specs for:
   - required field validation
   - duplicate names
   - slot/skeleton mismatch
   - test-mode solver validation
   - searchable post-create behavior
3. Align MCP craft tool outputs with upstream JSON shape.

Acceptance:

- `tests/craft.test.ts` behaviors are ported or intentionally mapped
- `chiasmus_craft` MCP cases pass with direct Crystal specs
- library/search integration for crafted templates is covered

### 3. Formalize Solve-Path Depth

Basic formalize parity exists, but the deeper solve path is still undercovered:

- `tests/formalize.test.ts` solve-path rows remain missing
- correction-loop behavior is only partially represented through older solver specs

Why this matters:

- this is the highest-risk end-to-end path in the system
- upstream formalize coverage includes correction-loop usage, diagnostics, and library recording

Work:

1. Port the remaining solve-path cases from `formalize.test.ts`:
   - successful Z3 end-to-end solve
   - successful Prolog reachability solve
   - correction-loop retry on bad initial formalization
   - failure/diagnostics when retries exhaust
   - enriched feedback prompt coverage
   - template use recording
2. Remove any reliance on accidental mock behavior.
3. Keep tests deterministic with explicit mock-agent responses.

Acceptance:

- all feasible `formalize.test.ts` rows are ported
- inventory rows for remaining formalize tests are updated

### 4. MCP Server Breadth

The repo now has several direct tool specs, but the upstream MCP surface is still only partially covered:

- many rows in `tests/mcp-server.test.ts` remain missing
- some rows are duplicated in the ledger as both missing and ported summaries

Why this matters:

- MCP is the user-facing API surface
- parity here catches response-shape drift quickly

Work:

1. Continue direct tool-level parity specs for missing cases:
   - `verify` malformed inputs, trace behavior, query requirements
   - `skills` search/list/by-name/error cases
   - `formalize` missing-problem and suggestion behavior
   - `solve` end-to-end and fallback behavior
   - `lint` parity once validation is ported
   - `craft` parity once craft is ported
2. Decide whether to add a lightweight Crystal in-memory MCP harness later.
3. Clean duplicate inventory rows so tool parity status is not contradictory.

Acceptance:

- major MCP behaviors are covered via direct tool specs even if transport-layer MCP harness is deferred
- stale duplicate missing rows are removed or reconciled in manifests

### 5. Graph Analysis And Graph MCP

Large unresolved graph tranche:

- `vendor/chiasmus/src/graph/analyses.ts`
- `vendor/chiasmus/tests/graph/analyses.test.ts`
- `vendor/chiasmus/tests/graph/mcp-integration.test.ts`

Why this matters:

- the extractor/parser foundation is mostly there
- graph analyses are a major user-facing capability still under-ported

Work:

1. Audit current Crystal graph analysis code against upstream API and test surface.
2. Port missing analysis behaviors:
   - callers/callees
   - transitive impact/path
   - dead-code
   - summary
   - facts/raw Prolog output
3. Add direct graph MCP tool specs for analysis requests and parameter validation.

Acceptance:

- `graph/analyses.test.ts` major behaviors are covered
- graph MCP integration cases have Crystal equivalents

### 6. Clojure Graph Support

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

### 7. Session Isolation And Concurrency

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

### 8. Benchmark And Dogfood Suites

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

### 9. Dynamic Adapter Discovery

Still intentionally deferred, but still a major source-level gap:

- `vendor/chiasmus/src/graph/adapter-registry.ts` runtime discovery path
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

### 10. LLM Compatibility Surface

Still missing compared to upstream:

- `vendor/chiasmus/src/llm/anthropic.ts`
- `vendor/chiasmus/src/llm/openai-compatible.ts`
- some `llm/types` parity rows
- streaming behavior in the mock adapter

Why this matters:

- local Crig integration is good, but upstream compatibility surface is still wider
- missing LLM rows will continue to show up in the manifests

Work:

1. Decide whether these rows should be treated as:
   - real missing parity
   - intentional architectural divergence because Crig replaces vendor adapters
2. For intentional divergence:
   - mark rows with explicit notes
3. For retained behavior:
   - port the minimal needed compatibility wrapper and tests
4. Implement mock streaming if upstream behavior depends on it.

Acceptance:

- no ambiguous “missing” rows remain for LLM adapters without an explicit rationale

## Recommended Execution Order

### Phase 1: Complete Core User-Facing Workflow

1. Validation/lint
2. Craft
3. Remaining formalize solve-path cases
4. Remaining MCP tool cases tied to the above

Reason:

- this closes the biggest user-visible parity gaps first
- it also reduces false negatives in later integration suites

### Phase 2: Finish Graph Feature Parity

1. Graph analyses
2. Graph MCP integration
3. Clojure graph support

Reason:

- parser/extractor foundation is already mostly present
- remaining work is primarily behavior completion and test coverage

### Phase 3: Concurrency And End-To-End Confidence

1. Session isolation/concurrency
2. Dogfood scenarios
3. Benchmark suites

Reason:

- these are better signoff gates after core functional parity is stable

### Phase 4: Deferred Architectural Gaps

1. Dynamic adapter discovery
2. LLM compatibility cleanup
3. Inventory hygiene and explicit divergence notes

Reason:

- these matter, but they are less blocking than the core verification flow

## Inventory Cleanup Tasks

The manifests currently still contain contradictory or stale rows in a few areas. This needs to be treated as part of the parity work, not as optional cleanup.

Work:

1. Reconcile duplicate MCP rows where summary rows are marked ported but concrete rows remain missing.
2. Reconcile any source rows now ported in Crystal but still marked missing.
3. Add explicit notes for intentional divergences, especially around Crig replacing upstream LLM adapter architecture.

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

## Immediate Next Step

Start with `validate` and `chiasmus_lint`, then move directly into `craft`. Those two slices unlock the largest remaining MCP and formalize gaps with the least architectural uncertainty.
