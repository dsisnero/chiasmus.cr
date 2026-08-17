# Chiasmus Crystal Parity Plan

## Current Inventory State (vendor/chiasmus @ `d1f1291e`)

Ledger reconciled against the pinned vendor revision on 2026-08-16.

_(The completed P20 notes below describe the earlier 07bbf4a → 576ed38 update; they are retained as implementation history.)_

| Manifest | Tracked | Ported | Partial | Intentional divergence | Missing |
|---|---|---:|---:|---:|---:|
| `typescript_port_inventory.tsv` | 605 | 507 | 0 | 98 | 0 |
| `typescript_source_parity.tsv` | 605 | n/a | n/a | n/a | n/a |
| `typescript_test_parity.tsv` | 1082 | n/a | n/a | n/a | n/a |

Current workflow split:

- `typescript_port_inventory.tsv` is the curated source-focused ledger.
- `typescript_source_parity.tsv` is the exhaustive generated source manifest.
- `typescript_test_parity.tsv` is the exhaustive generated test manifest.
- `check_port_inventory.sh` proves curated source coverage only.
- `check_test_parity.sh` is the exhaustive test drift gate.

### Intentional Divergences (98 items)

| Subsystem | Items | Rationale |
|---|---|---|
| Crig (LLM adapters + embeddings) | ~58 | Replaces Anthropic, OpenAI-compatible, Azure OpenAI, Mock adapters |
| BM25 shard | ~7 | Replaces upstream BM25 tokenize/search/index |
| Manifest discovery | ~2 | Replaces Node.js dynamic module loading |
| tree_sitter shard | ~1 | Replaces upstream getNativeParser |
| Clojure WASM parser | ~3 | Deferred; source-form extractor used |
| Z3 solver config | ~1 | Constructor config instead of global timeout |
| Uncheckable Ansch/vendor defaults | ~14 | Provider defaults owned by Crig/configuration |

### Reconciled Inventory Scope

P28 established a source-only curated ledger and refreshed both generated manifests.
The 1,082 upstream tests—including helpers, fixtures, and benchmark test declarations—
belong solely in `typescript_test_parity.tsv`; they are not source implementation rows.
All 605 source declarations are now mapped as ported, partial, or intentionally
divergent. The 20 Node `node-llama-cpp` local-embedding declarations are intentionally
divergent: Crystal validates the configuration and routes configured local models to
Ollama, but does not claim Node model lifecycle parity.

### Source-Only Work Scope (reconciled)

This is the implementation-facing scope for `src/` against `vendor/chiasmus/src/`.
The feature phases below capture the completed mappings and documented behavioral
substitutions.

| Upstream subsystem | Declarations | Planned phase | Expected disposition |
|---|---:|---|---|
| `graph/` | 35 | P29–P30 | Map extractor/parser/cache/analysis APIs and add behavior specs where the public contract differs. |
| `skills/` | 22 | P31 | Map lifecycle, persistence, learning, and search-index methods to the Crystal template store. |
| `search/` | 17 | P32 | Reconcile the existing VectorStore and embedding-cache APIs, including persistence/serialization behavior. |
| `llm/` | 11 | P35 | Record Crig substitutions as intentional divergences or add a compatibility seam; do not recreate provider clients. |
| `solvers/` | 11 | P34 | Specify lifecycle and correction semantics; document crolog/Z3 implementation substitutions. |
| `mcp-server.ts` | 10 | P36 | Map server construction and tool-handler dispatch to `mcp_server/`. |
| `formalize/engine.ts` | 9 | P33 | Characterize the formalization pipeline through the Crig boundary. |
| `config.ts`, `review.ts` | 2 | P36 | Map defaults and focus validation. |
| `llm/local-embeddings.ts`, local embedding config | 25 | P35 | Port local-model configuration and lifecycle, or document a supported alternative. |

## Feature-Sized Phases (P28-P39)

Each phase starts red: characterize the upstream behavior in a Crystal spec (or map
an existing equivalent spec) before changing implementation. On completion, update
only the affected curated inventory rows with Crystal references and run the relevant
parity check; generated manifests remain generated artifacts.

| Phase | Feature | Scope | Completion evidence |
|---|---|---|---|
| P28 ✓ | Inventory reconciliation baseline | Reconciled the curated ledger to the 605 upstream source declarations; refreshed generated source (605) and test (1,082) manifests; classified local-embedding configuration and the Node/Ollama substitution. | Completed: `check_port_inventory`, `check_source_parity`, and `check_test_parity` pass in strict tree-sitter mode. |
| P29 ✓ | Graph ingestion and resolution | `adapter-registry`, `extractor`, `parser`, `suffix-index`, `tsconfig-aliases`, and `type-env` (17 source IDs). | Completed: characterization specs cover loading, parse failure, alias resolution, and extraction; static/native Crystal replacements for Node module loading, WASM configuration, and public TypeEnv APIs are documented. |
| P30 ✓ | Graph persistence and analysis | `graph/cache` and `graph/analyses` (18 source IDs), including cache lifecycle, locking, snapshots, and analysis entry points. | Completed: cache/analysis APIs are mapped; SQLite WAL replacements for JSON manifest/proper-lockfile internals are documented; snapshot/cache specs pass. |
| P31 ✓ | Skills lifecycle | `skills/library`, `learner`, `craft`, `relationships`, and `starters` (22 source IDs). | Completed: upstream's 14-template starter corpus and all relationship edges are covered; persistence, promotion, and search-index specs pass. |
| P32 ✓ | Semantic-search storage | `embedding-cache`, `search/engine`, and `vector-store` (17 source IDs). | Completed: corpus signatures and vector dimensions now follow upstream; specs cover cache persistence, mutations, search, and serialization. |
| P33 ✓ | Formalization pipeline | `formalize/engine` (9 source IDs): instruction assembly, response cleanup, selection, fill/fix, lint loop, and solve. | Completed: bounded lint remediation now includes upstream-style auto-fix/error feedback and oscillation detection before solver correction; Crig supplies the equivalent async completion boundary. |
| P34 ✓ | Solver sessions and correction | `correction-loop`, `session`, `z3-solver`, and `prolog-solver` (11 source IDs). | Completed: lifecycle, disposal, correction, and error semantics are specified; crolog’s stable per-query wall-clock/answer limits replace the upstream Node per-query inference-budget override. |
| P35 ✓ | LLM-provider and local-embedding compatibility | Cloud/mock adapters (11 source IDs) plus local embeddings/configuration: env/config precedence and the supported Ollama alternative. | Completed: Crig replaces vendor adapter transport; Azure env/provider routing is covered. Node-only `node-llama-cpp` lifecycle semantics remain an explicit Ollama-backed intentional divergence, reconciled in P28. |
| P36 ✓ | MCP-server composition | `mcp-server`, configuration defaults, and review focus validation (12 source IDs). | Completed: tool registration/gating, review focus validation, and isolated server construction are characterized. Crig completion and Node-only local embeddings are documented divergences. Wire-payload compatibility is completed separately by P38. |
| P37 ✓ | Benchmark-suite parity | Upstream benchmark scenario solvers, runners, and result interfaces (20 rows). | Completed: all five deterministic Chiasmus-vs-traditional scenarios and typed results are covered by Crystal benchmark specs; Crystal Spec replaces TypeScript runSuite. |
| P38 ✓ | MCP collection-payload wire compatibility | `chiasmus_skills` query/list and `chiasmus_verify` Prolog batch now preserve the upstream top-level array contracts while retaining the Crystal `{status: ...}` extension on object-shaped responses. | Completed: transport specs cover query `{template, metadata, score}`, unqualified/filtered `{template, metadata}` listings, ordered batch `SolverResult[]`, stop-on-first-error, and absent object-only `structured_content`; focused tool/MCP specs, build, and strict parity checks pass. |
| P39 ✓ | MCP graph snapshot runtime capability | Graph extraction uses Crystal 1.21 runtime parallel execution contexts without legacy compiler flags; `CHIASMUS_GRAPH_PARALLEL=0` remains the explicit fiber-only opt-out. | Completed: ordinary release builds and install artifacts have no legacy flags; resolver and multi-file snapshot/cache-reuse regressions pass, along with scoped format/lint/build gates. |

Dependency order: P28 first; then P29 → P30, P31 and P32 independently, P33, P34 and P35 independently, P36, P37, P38, and P39. Test-helper rows are closed with their owning feature phase rather than treated as standalone product work.

P38 deliberately excludes solve-history serialization, learn extraction/rejection payloads, and graph/map raw-output conventions. Those are separate user-visible contracts and will be planned as a later feature rather than folded into a sequence of helper-sized patches.

## Inventory Safety And Vendor Updates

The inventory workflow is safe for user/agent updates as long as we keep the curated/generated split:

- Curated ledger: `plans/inventory/typescript_port_inventory.tsv`
- Generated/drift snapshots: `plans/inventory/typescript_source_parity.tsv`, `plans/inventory/typescript_test_parity.tsv`
- Do not regenerate the curated ledger over existing work.
- Use `ruby scripts/sync_port_inventory.rb --manifest plans/inventory/typescript_port_inventory.tsv --source vendor/chiasmus --language typescript --parser tree-sitter` to append newly discovered source rows without clobbering statuses or refs.
- Use check scripts to detect new/stale IDs after vendor pulls.

Current drift checks catch:

- New upstream API/test IDs that are not in inventory.
- Removed/renamed upstream IDs that are stale in inventory.
- Invalid statuses.
- `ported`/`partial` rows missing Crystal references.

## Completed Features (P0-P7)

All prior porting work is complete. See implementation history below for details on each phase:

| Phase | Feature | Status |
|---|---|---|
| P0 | Vendor Refresh And Change Impact Tracking | Implemented |
| P1 | Dynamic Adapter Discovery | Implemented |
| P2 | Clojure Tree-Sitter Runtime Support | Implemented (parser divergence) |
| P3 | Tree-Sitter Discovery And Inventory Quality | Implemented |
| P3.1 | Multi-Language Core Abstractions | Implemented |
| P3.2 | Remaining Languages + CLI Integration | Implemented |
| P4 | Prolog Fact Inventory And Conversion Rules | Implemented |
| P5 | MCP Transport-Level Harness | Implemented |
| P6 | Release Hardening | Implemented |
| P7 | Codeium-Parse Predicate Support | Implemented (P7.1-P7.7) |
| **P8** | **VectorStore** | **Implemented** |
| **P9** | **Multi-Language Code Index** | **Implemented** |
| **P10** | **Vendor Refresh & Rust Graph Parity (07bbf4a)** | **Implemented** |
| **P11** | **Search Engine Lazy Dimension Discovery** | **Implemented** |
| **P12** | **MCP Tool Gating + Inventory Housekeeping** | **Implemented** |
| **P13** | **C# Graph Walker** | **Implemented** |
| **P14** | **JSON::Serializable Refactor + Dead Code** | **Implemented** |
| **P15** | **Walker Fixes + Enum/Union Extraction** | **Implemented** |
| **P16** | **GraphCache + FileNode + 37x Speedup** | **Implemented** |
| **P17** | **CLI Friendliness + Output Schemas + Search (Ollama)** | **Implemented** |
| **P18** | **Diff/Snapshot Analysis Wiring** | **Implemented** |
| **P19** | **Graph Walker: C++** | **Implemented** |
| **P20** | **Vendor Refresh 576ed38 (v0.1.24) — `converged` clarity, Prolog lint, embedding formalize** | **Implemented** |
| **P21** | **Parallel Graph Extraction** | **Implemented** |
| **P23** | **Parallel File I/O** | **Implemented** |
| **P24** | **Async Cache & Snapshot Writes** | **Implemented** |
| **P25** | **Parallel Brandes' Algorithm (Betweenness)** | **Implemented** |
| **P26** | **Parallel Insight Fact Generation** | **Implemented** |
| **P27** | **Parallel Surprise Detection** | **Implemented** |

### P21: Parallel Graph Extraction — Implemented

**Goal:** parallelize `Graph::Extractor.extract_graph` using the `discovery/pipeline.cr` bounded-concurrency pattern.

**Implementation:**
- `extract_single_file` — pure method returning `CodeGraph` for one file, no shared state
- `merge_graph_under_lock` — `Mutex`-guarded merge of per-file results
- Semaphore `Channel(Nil)` bounded to `System.cpu_count`; spawn + result `Channel(CodeGraph)`
- Removed `extract_per_file_graph` (was mutating shared accumulators, had no callers)

**Acceptance:**
- `[x]` `extract_graph` uses parallel fiber-per-file pattern with bounded concurrency
- `[x]` `CodeGraph` merge is fiber-safe via `@@merge_mutex : Mutex`
- `[x]` Existing graph specs pass identically (deterministic output)
- `[x]` Perf: 3-file extraction 5.75s → 1.67s (~3.4x speedup)
- `[x]` 5 new specs: multi-file correctness, 10-fiber concurrent calls, determinism

### P20: Vendor Refresh 576ed38 (v0.1.21 → v0.1.24) — Implemented

**Upstream changes (07bbf4a → 576ed38):** 11 files changed, 263 insertions, 42 deletions.

**Git range:** `git -C vendor/chiasmus diff 07bbf4a..576ed38 --stat`

| # | Upstream File | Change Description | Crystal File | Status |
|---|--------------|-------------------|-------------|--------|
| 1 | `src/formalize/engine.ts` | **Embedding-based template selection** — optional `EmbeddingAdapter` for cosine-similarity re-ranking; BM25 fallback. New `selectByEmbedding()` + `l2Norm` helper | `src/chiasmus/formalize/engine.cr` | **Ported** |
| 2 | `src/formalize/engine.ts` | **System prompt update** — "SLOT format examples illustrate syntax only, never copy values" warning | `src/chiasmus/formalize/engine.cr:25` (FORMALIZE_SYSTEM) | **Ported** |
| 3 | `src/formalize/engine.ts` | **`converged` doc comment** — explains `converged` is not a verdict on the property | `src/chiasmus/formalize/engine.cr:18` (SolveResult) | **Ported** |
| 4 | `src/formalize/validate.ts` | **Prolog lint fix** — check last clause termination (`endsWith(".")`), detect float decimal as false positive, updated error messages | `src/chiasmus/formalize/validate.cr:220-222` | **Ported** |
| 5 | `src/skills/library.ts` | **Extract `getTemplateSearchText`** — shared public method for BM25 + embedding re-ranking (used by #1) | `src/chiasmus/skills/library.cr:269` (`build_search_text`, currently private) | **Ported** |
| 6 | `src/solvers/correction-loop.ts` | **Doc: `converged` clarification** — "converged reports only that the loop reached a non-error result, not a proof" | `src/chiasmus/solvers/correction_loop.cr:12-18` | **Ported** |
| 7 | `src/solvers/prolog-solver.ts` | **Wrapper variable hygiene** — rename `Err`/`EStr` to collision-resistant names, strip internal vars from answer bindings | `src/chiasmus/solvers/prolog_solver.cr` | **N/A** (crolog FFI, not prolog-wasm) |
| 8 | `src/mcp-server.ts` | **Solve tool description** — clarify `converged` ≠ proof; read `result.status` for actual verdict | `src/chiasmus/mcp_server/tools/solve.cr:46-53` | **Ported** |
| 9 | `src/mcp-server.ts` | **Version from `package.json`**, embedding wiring into `FormalizationEngine` | `src/chiasmus/mcp_server/server.cr` | Already done (uses `Chiasmus::VERSION`) |
| 10 | `tests/validate.test.ts` | 4 new Prolog lint tests (unterminated last clause, float decimal, float in terminated clause passes, error messages) | `spec/chiasmus/formalize/validate_spec.cr` | **Ported** |
| 11 | `tests/prolog-solver.test.ts` | 3 wrapper-variable hygiene tests | `spec/chiasmus/solvers/prolog_solver_spec.cr` | **N/A** (crolog backend) |
| 12 | `tests/mcp-server.test.ts` | 2 tests: version from package.json, `converged` tool description | `spec/chiasmus/mcp_server/server_spec.cr`, `spec/mcp_server/tools/solve_spec.cr` | **Ported** |

#### Porting Plan

**Priority 1 — Small/targeted changes (items 2-4, 6, 8):**
- Update `FORMALIZE_SYSTEM` constant in `engine.cr` to include the SLOT format warning
- Add doc comment on `SolveResult.converged` field
- Fix Prolog lint: change `includes?('.')` to check `ends_with?('.')` for last clause, update error messages
- Add doc comment on `correction_loop` method about `converged` semantics
- Update `tool_description` in `solve.cr` to clarify `converged` vs `result.status`

**Priority 2 — Library refactor (item 5):**
- Make `build_search_text` a public method (or add `get_template_search_text` wrapper) on `Library`
- Ensure it doesn't include tips (match upstream behavior for embedding consistency)

**Priority 3 — Embedding formalize (item 1):**
- Add optional `@embedding` field to `Engine(M)` — type depends on Crig embedding model
- Add `select_by_embedding(problem)` method with cosine similarity ranking
- Add `l2_norm` helper
- Update `formalize()` to try embedding first, fall back to BM25
- Wire embedding from `Server` into `Engine` constructor
- This requires an embedding model to be resolvable at Engine construction time

**Priority 4 — Tests (items 10, 12):**
- Port 4 Prolog lint tests to `validate_spec.cr`
- Port `converged` tool description test to `solve_spec.cr`
- Items 7, 11 (prolog-solver wrapper vars) are N/A — Crystal uses crolog FFI which doesn't inject a `catch` wrapper

#### Intentional Divergences (P20)

| Subsystem | Item | Rationale |
|-----------|------|-----------|
| Prolog solver | Wrapper variable hygiene (items 7, 11) | Crystal uses crolog (SWI-Prolog FFI) via `PL_Q_CATCH_EXCEPTION` — no `catch`/`call_with_inference_limit` wrapper that would leak internal vars |
| MCP version | package.json version (item 9) | Already reads from `Chiasmus::VERSION` constant set at compile time |

### P19: C++ Graph Walker — Implemented (2026-06-15)

Completed the Crystal-native C++ walker with:
- **Namespace tracking** — `namespace_definition` handler pushes scope and defines `SymbolKind::Module`
- **Enum extraction** — `enum_specifier` handler extracts enum name + enumerator members
- **Constructor/destructor detection** — `function_definition` inside class body where name matches class → `.ctor`; `destructor_name` descendant → `.dtor`
- **Refactored** `handle_cpp_declaration` into `handle_cpp_class`, `handle_cpp_namespace`, `handle_cpp_enum`, `handle_cpp_function`, `record_cpp_special_method` to keep cyclomatic complexity within limits
- Added `SymbolKind::Module` to the shared enum (produces `"module"` in Prolog facts)
- 5 new specs: namespace defines, enum+members, class enum, constructor, destructor — 12 total, 0 failures

### P13: C# Graph Walker — Crystal-Native Feature

**Goal:** add C# tree-sitter graph extraction (class, interface, struct, enum, method, constructor, namespace, calls, imports) to the graph walker pipeline.

**Status:** upstream `vendor/chiasmus` does not have a C# graph walker. This is a Crystal-native addition following the same patterns as the existing 8 walkers (go, rust, java, crystal, python, javascript, clojure, shared).

**Scope:**
- `src/chiasmus/graph/walkers/csharp.cr` — new walker
- `src/chiasmus/graph/extractor.cr` — wire `walk_csharp` into `extract_with_walkers`
- `src/chiasmus/graph/parser.cr` — ensure `.cs` extension maps to csharp
- Specs: RED-GREEN TDD covering class/interface/struct/enum definitions, method calls, namespace imports

**Tree-sitter C# node types handled:**
| Node | SymbolKind |
|---|---|
| `class_declaration` | Class |
| `interface_declaration` | Interface |
| `struct_declaration` | Class |
| `enum_declaration` | Type |
| `method_declaration` | Method |
| `constructor_declaration` | Method |
| `namespace_declaration` | scope container |
| `invocation_expression` | call edge |
| `using_directive` | import |

### P8: VectorStore — In-Process Linear-Scan Cosine Search (Completed)

**Goal:** port the only remaining missing subsystem — `src/search/vector-store.ts`.

**Crig consideration:** Crig provides `VectorStoreIndex`/`InMemoryVectorStore`/`SqliteVectorStore` at a higher abstraction level (document→embed→store pipeline with `EmbeddingModel`). These are not drop-in replacements for the upstream low-level VectorStore which takes pre-computed raw vectors, stores arbitrary metadata, and provides explicit CRUD. Crig's `VectorDistance`/`cosine_similarity` requires `Embedding` wrapper instances — unnecessary allocation for O(N·D) bulk queries. Use Crig concepts (brute-force cosine, L2 norm caching) but implement as a thin standalone class.

**Upstream:** `vendor/chiasmus/src/search/vector-store.ts` (159 lines)

**Inventory:** 18 items (8 source, 10 test), all `missing`

#### Implementation

**Source file**: `src/chiasmus/search/vector_store.cr`
**Spec file**: `spec/chiasmus/search/vector_store_spec.cr`

| TypeScript | Crystal |
|---|---|
| `VectorStore` (class) | `VectorStore` (class) |
| `VectorStoreConfig { dimension }` | NamedTuple or struct |
| `VectorRecord { id, vector, metadata? }` | Record/struct |
| `VectorSearchHit { id, score, metadata? }` | Record/struct |
| `InternalRow` (precomputed norm) | Private struct |
| `number[]` (vectors) | `Array(Float64)` |
| `Map<string, InternalRow>` | `Hash(String, InternalRow)` |
| `Record<string, unknown>` (metadata) | `JSON::Any` |
| `serialize()` / `parse(raw)` | `to_json` / `from_json` |

#### TDD Test Plan

9 specs (port upstream tests in order):

```
1. inserts vectors and finds nearest by cosine similarity
2. upsert replaces an existing id
3. remove deletes a vector by id
4. has() checks for id presence
5. rejects vectors of wrong dimension
6. returns empty array when store is empty
7. topK > size returns all vectors
8. serialize → parse round-trips
9. parse rejects an incompatible schema version
```

#### Acceptance

- `[x]` 9 specs pass, upstream edge cases preserved (zero-norm, dimension mismatch, metadata round-trip)
- `[x]` 18 inventory rows: `missing` → `ported` with crystal_refs
- `[x]` `check_port_inventory.sh` reports 0 missing, 0 stale
- `[x]` Format + lint clean

### P9: Multi-Language Code Index — Implemented

P9.1-P9.6 all implemented. 45 specs, 0 failures. See `plans/code_index.md` for full design.

#### P9.4: MCP Search Tool Integration — Implemented (2026-06-05)

Updated `src/chiasmus/mcp_server/tools/search.cr`:
- Added `languages` and `kinds` optional filter params to input schema
- Fixed schema type mismatch (inline `Hash` literals → `SchemaProperty`/`ArraySchemaProperty` unified types)
- 7 new specs in `spec/mcp_server/tools/search_spec.cr`
- Cleaned up duplicate `initialize`/`count` methods in `code_index.cr`
- Backward compatible: existing params unchanged

### P10: Vendor Refresh & Rust Graph Parity (07bbf4a) — Implemented

**Upstream changes (c6cb087 → 07bbf4a):**
- Rust tree-sitter support added to parser + 7 Rust extraction functions in extractor
- Rust doc comment handling (`isDocShape`, `normalizeCommentText` updates)
- Search engine `tryDimension` for lazy dimension discovery
- Embedding factory fallback reorder (DeepSeek after OpenRouter)
- MCP tool gating (hide unconfigured-backend tools from list)

**Porting work:**

#### Rust Walker (7 new functions → ported)
Rewrote `src/chiasmus/graph/walkers/rust.cr` to match upstream behavior:
- Added signature extraction (`extract_rust_signature`, `collapse_signature`)
- Added pub/export tracking (`rust_pub?`)
- Added call extraction from function bodies (`extract_rust_calls`)
- Fixed `impl_item`: no longer defines itself as Class (just scope provider)
- Fixed `mod_item`: no longer defines as Interface (just recurses into body)
- Fixed `trait_item`: passes trait name as `impl_type` so trait methods get `contains` relation
- Added `union_item` and `function_signature_item` cases
- Fixed use declaration handling: `named_child` API, `scoped_use_list`, `use_as_clause` with alias support, `use_wildcard` skip
- 16 specs (7 new + 9 updated existing), 0 failures

#### Changed specs
- `extracts use declarations`: source changed from fully-qualified `std::collections::HashMap` to path-only `std::collections` (matches upstream)
- `extracts module declarations`: renamed to "recurses into modules without defining the module name"
- New specs: signature extraction, pub/export tracking, renamed imports, trait method attachment, impl-type dedup, method calls, associated function calls

#### Intentional Divergences
- **Embedding config tests** (6 tests, `tests/create-embedding-from-env.test.ts`): Crig replaces `createEmbeddingFromEnv`
- **Search engine `tryDimension`**: Crig's `EmbeddingModelDyn` always knows dimension via `ndims`; lazy discovery unnecessary
- **Search engine `LazyDimAdapter` test**: Not applicable under Crig
- **Anthropic LLM fallback reorder**: All LLM adapters are intentional divergence (Crig)

### P11: Search Engine `tryDimension` — Intentional Divergence

Upstream added `tryDimension` to `src/search/engine.ts` to handle adapters whose dimension is unknown until first `embed()` call. Crig's `EmbeddingModelDyn` always exposes `ndims` upfront, making lazy dimension discovery unnecessary. Marked as `intentional_divergence` in inventory.

### P12: MCP Tool Gating + Inventory Housekeeping — Implemented

Upstream added tool list filtering in `src/mcp-server.ts`: hides `chiasmus_search` when no embedding provider, hides `chiasmus_learn` when no LLM. Documented in inventory with crystal_refs. Full transport-level integration deferred (requires MCP framework changes). Inventory now clean: 1416 items tracked, 0 missing, 0 stale.

## Implementation History

1. **P0 Vendor Refresh And Change Impact Tracking** — Implemented.
2. **P1 Dynamic Adapter Discovery** — Implemented.
3. **P2 Clojure Tree-Sitter Runtime Support** — Implemented with parser divergence.
4. **P3 Tree-Sitter Discovery And Inventory Quality** — Implemented.
5. **P3.1 Multi-Language Core Abstractions** — Implemented.
6. **P3.2 Remaining Languages + CLI Integration** — Implemented.
7. **P4 Prolog Fact Inventory And Conversion Rules** — Implemented.
8. **P5 MCP Transport-Level Harness** — Implemented.
9. **P6 Release Hardening** — Implemented.
10. **P7 Codeium-Parse Predicate Support** — Implemented (P7.1-P7.7 complete)
11. **P8 VectorStore** — Implemented (2026-05-28)
12. **P9 Multi-Language Code Index** — Implemented (P9.1-P9.6 complete, MCP tool integrated)
13. **P10 Vendor Refresh & Rust Graph Parity** — Implemented (2026-06-05)
14. **P11 Search Engine Lazy Dimension Discovery** — Intentional Divergence (2026-06-05)
15. **P12 MCP Tool Gating + Inventory Housekeeping** — Implemented (2026-06-05)

- `[x]` Re-running discovery does not duplicate adapters.
- `[x]` Built-in language support still wins where intended.

### P2: Clojure Tree-Sitter Runtime Support — Implemented With Parser Divergence

**Goal:** turn the deferred Clojure graph rows into executable runtime parity.

Inventory drivers:

- 14 `tests/graph/clojure.test.ts` rows were marked `intentional_divergence`.
- Clojure walker helpers were ported, but runtime parser execution was blocked.

Current status:

- `.clj` extension mapping exists.
- Clojure graph extraction is executable through `Extractor.extract_graph`.
- Upstream depends on WASM tree-sitter grammar behavior.
- Crystal runtime still does not parse Clojure with the WASM tree-sitter grammar.
- Crystal now uses a narrow source-form extractor for Clojure forms until a WASM parser is available.

Implemented path:

- Added `ClojureSourceExtractor` as the parser-independent execution path for Clojure graph behavior.
- TDD specs cover upstream Clojure extractor and Prolog integration expectations.
- Actual `parseSourceAsync` WASM behavior remains an intentional parser divergence.

Deliverables:

- `[x]` Parser-independent Clojure form extractor.
- `[x]` Direct specs for namespace imports, `defn`, `defn-`, namespace-qualified call normalization, dedup, and multi-file behavior.
- `[x]` Direct specs for Clojure graph Prolog reachability and dead-code queries.
- `[x]` WASM grammar loader remains explicitly deferred behind the parser interface as an intentional divergence.

Acceptance:

- `[x]` Clojure graph behavior is executable in Crystal specs even though real WASM parsing remains optional.
- `[x]` Upstream Clojure extractor/prolog tests are reclassified to `ported`.
- `[x]` Future WASM support path is documented: if added later, the single upstream Clojure parser test can be reclassified from `intentional_divergence` to `ported`.

### P3: Tree-Sitter Discovery And Inventory Quality — Implemented

**Goal:** improve inventory discovery so significant declarations are not missed by regex.

Why this matters:

- The parity skill now warns that regex is bootstrap-only when significant declaration shape matters.
- This repo has TypeScript, graph walkers, parser adapters, and solver constants where robust symbol discovery matters.

Implementation:

- `src/chiasmus/discovery.cr` — Crystal module using tree-sitter Query API for TypeScript symbol extraction.
- Tree-sitter query patterns cover: `class`, `interface`, `type`, `function`, `function` (arrow functions), `method` (class-qualified), `const` (UPPERCASE only), and `test` (describe/it/test).
- `src/chiasmus_discover.cr` — CLI entry point (`chiasmus-discover` target in `shard.yml`).
- The installed `cross-language-crystal-parity` skill bundle’s
  `parity_inventory_lib.rb` now delegates to the Crystal discovery binary when
  `PORT_PARSER=tree-sitter` or `--parser tree-sitter` is requested.
- Platform-agnostic grammar loading: searches `vendor/grammars/` with platform-appropriate extensions (`.dylib`/`.so`/`.dll`), tries multiple library naming conventions (`libtree-sitter-{lang}.ext`, `{lang}.ext`, `parser.ext`), subdirectory probes, and multiple symbol naming conventions.
- Regex fallback mode: clearly reports `parser_mode = "regex"` in notes when tree-sitter is unavailable.
- Stable IDs: `{relative_path}::{kind}::{name}` matching existing inventory format.

Deliverables:

- `[x]` Tree-sitter-backed discovery for TypeScript first.
- `[x]` Query patterns for classes, interfaces, type aliases, constants, functions, class methods, and tests.
- `[x]` A fallback mode that reports "regex fallback used" clearly.
- `[x]` Stable IDs matching the existing inventory format.
- `[x]` 21 specs covering all declaration types, ID format, parser mode tracking, regex fallback, and deduplication.

Acceptance:

- `[x]` Running with `PORT_PARSER=tree-sitter` produces the same or better item coverage than current regex for `vendor/chiasmus`.
- `[x]` Any new IDs are explainable, not discovery noise.
- `[x]` The check scripts can identify whether a scan was tree-sitter-backed or fallback.

### P3.1: Multi-Language Core Abstractions — Implemented

**Goal:** extend tree-sitter discovery from TypeScript-only to all languages with SOLID abstractions and non-blocking concurrency.

Design document: `plans/design/multi_language_discovery.md`

Implementation:

- `src/chiasmus/discovery/extractor.cr` — `LanguageExtractor` abstract struct (Strategy pattern) + `QueryExtractor` base with `run_query`, `post_filter`, `process_query`, `qualify_method` helpers.
- `src/chiasmus/discovery/registry.cr` — `ExtractorRegistry` mapping file extensions → extractors.
- `src/chiasmus/discovery/grammar_loader.cr` — `GrammarLoader` with platform-aware shared library loading (`.dylib`/`.so`/`.dll`, multiple naming conventions, subdirectory probes).
- `src/chiasmus/discovery/pipeline.cr` — `Pipeline` with bounded concurrency (fiber-per-file, `Channel(Nil)` semaphore, `select/when/timeout`).
- Extractors implemented: TypeScript, Python, Go, Java, Rust.
- `spec/chiasmus/discovery/extractor_spec.cr` — 9 core abstraction specs.
- `spec/chiasmus/discovery/extractors_spec.cr` — 19 specs across Python, Go, Java, Rust extractors.
- `spec/chiasmus/discovery/pipeline_spec.cr` — 6 pipeline specs (concurrent processing, multi-language, dedup).

### P3.2: Remaining Languages + CLI Integration — Implemented

**Goal:** complete all 10 languages and wire into pipeline.

Implementation:

- Extractors: JavaScript, TSX (delegates to TypeScript), Ruby, Crystal, Scala.
- `spec/chiasmus/discovery/p3_2_extractors_spec.cr` — 15 specs across JS, Ruby, Crystal, Scala extractors.
- `Pipeline` accepts `Array(LanguageExtractor)`, auto-resolves files by extension.
- `discovery.cr` delegates to `GrammarLoader` and accepts `Pipeline` for future CLI integration.

Acceptance:

- `[x]` All 19 languages have working tree-sitter extractors with TDD/golden specs (573 total).
- `[x]` Pipeline processes files concurrently with bounded parallelism.
- `[x]` SOLID: new language = new `QueryExtractor` subclass, no Pipeline/Registry changes.
- `[x]` Format + ameba lint clean.

### P4: Prolog Fact Inventory And Conversion Rules — Implemented

**Goal:** make parity status and conversion rules queryable.

Why this matters:

- Chiasmus has several intentional replacement layers: Crig for LLMs, crolog/SWI-Prolog for Tau Prolog, BM25 shard for upstream BM25, and explicit registration for adapters compiled into the Crystal binary.
- These are easier to audit as facts than as prose scattered across inventory notes.

Implementation:

- `plans/inventory/conversion_rules.tsv` — 18 conversion rules mapping upstream TypeScript patterns to Crystal replacements across 6 subsystems (LLM adapters, Prolog, BM25, adapter registration, tree-sitter, Z3).
- The installed `cross-language-crystal-parity` skill bundle’s
  `generate_inventory_facts.rb` deterministically reads port inventory, source
  parity, test parity, and conversion rules to produce Prolog facts.
- `plans/inventory/parity_facts.pl` — 2,073 Prolog facts including:
  - `inventory_item/5` — all 505 tracked items with kind, status, refs, notes.
  - `status/2` — status of each item.
  - `ported_item/1`, `partial_item/1`, `missing_item/1` — status-filtered facts.
  - `intentional_divergence/2` — 37 intentional divergences with rationale.
  - `conversion_rule/5` — 18 upstream-to-Crystal replacement rules.
  - `source_api/4`, `source_test/4` — source and test parity tracking.
- Example Prolog queries included in the facts file header for:
  - All intentional divergences by subsystem (sub_atom filter).
  - Changed upstream items after vendor pull.
  - Ported rows without direct specs.
  - Rows impacted by a conversion rule.
- The parity fact generator avoids newer Ruby-only APIs so it runs under the
  same Ruby available to the Crystal spec harness.

Deliverables:

- `[x]` `plans/inventory/conversion_rules.tsv` with 18 mapping rules across 6 subsystems.
- `[x]` Installed parity skill support for deterministic fact generation.
- `[x]` `plans/inventory/parity_facts.pl` with 2,073 facts and example queries.
- `[x]` Specs validating fact generation correctness and determinism.

Acceptance:

- `[x]` A reviewer can ask Prolog "what changed?", "what is intentionally divergent?", and "what conversion rule explains this row?"
- `[x]` Fact generation is deterministic and does not edit curated inventory.

### P5: MCP Transport-Level Harness — Implemented

**Goal:** complement direct tool specs with transport-level MCP coverage.

Current status:

- Direct tool specs cover major MCP behavior.
- Upstream uses an in-memory MCP client/server transport.
- Crystal now has a reusable in-memory transport harness and transport-level specs.

Implementation:

- `spec/support/mcp_test_harness.cr` — Reusable `MCPTestHarness::Instance` class that:
  - Creates linked `InMemoryTransport` pair via `MCP::Shared::InMemoryTransport`.
  - Builds `MCP::Server::Server` with capabilities, registers tools via `add_tool`.
  - Creates `MCP::Client::Client`, connects both ends (handshake).
  - Provides `list_tools`, `call_tool` helpers returning parsed JSON.
  - Tool registry supports full 9-tool catalog; currently wired for verify + graph.
- `spec/chiasmus/mcp_server/mcp_transport_spec.cr` — 8 transport-level specs:
  - `tools/list` returns correct names and descriptions.
  - `chiasmus_verify` verifies tautology and rejects missing params.
  - `chiasmus_graph` returns summary and validates analysis enum schema.
  - Error handling: unknown tool rejection and connection resilience.
- Fixed 4 pre-existing `JSON::Any.new(Array(String))` issues in verify.cr, skills.cr, tool_schemas.cr.

Note: Craft/Skills/Formalize/Solve tools require `MCPServer.current_server` scaffolding (not yet wired for in-memory transport). These remain covered by direct tool specs. Transport coverage for them is deferred until `current_server` is mockable.

Deliverables:

- `[x]` Lightweight Crystal MCP in-memory transport harness.
- `[x]` Transport-level specs for tool listing and JSON response shape.
- `[x]` Coverage for `chiasmus_verify` and `chiasmus_graph` through transport boundary.
- `[x]` Transport specs for error handling and connection resilience.

Acceptance:

- `[x]` Tool behavior is verified through the same boundary a real MCP client uses.
- `[x]` Direct tool specs remain fast unit coverage; transport specs cover integration.

### P7: Codeium-Parse Predicate Support — Completed

**Goal:** port codeium-parse custom query predicate handling and enhance extractors with enriched captures (doc, params, return_type, lineage, references).

Inventory drivers:

- Vendored `vendor/codeium-parse/queries/*.scm` (19 language query files with custom predicates).
- Vendored `vendor/codeium-parse/goldens/*.golden` (expected output format for 17 languages).
- Existing extractors lack doc comments, parameters, return types, lineage metadata, and call/class references.

Design document: `plans/design/codeium_parse_predicates.md`

#### P7.1: Tree-Sitter Shard Predicate Parsing — Implemented

Implementation:

- `lib/tree_sitter/src/tree_sitter/predicate.cr` — `Predicate` class + `Predicate::Arg` struct with typed args (Capture/String).
- `lib/tree_sitter/src/tree_sitter/query.cr` — `Query#predicates_for_pattern`, `Query#capture_name_for_id`, `Query#string_value_for_id`.
- Pushed to `dsisnero/crystal-tree-sitter` branch `feat/query-predicate-processing`.
- 15 TDD specs for all predicate types: `#eq?`, `#not-eq?`, `#match?`, `#not-match?`, `#set!`, `#select-adjacent!`, `#has-type?`, `#lineage-from-name!`, `#not-has-parent?`, `#strip!`, multiple predicates.

Deliverables:

- `[x]` `Query#predicates_for_pattern(UInt32)` → `Array(Predicate)`.
- `[x]` `Predicate` with `name : String` and `args : Array(Arg)`.
- `[x]` `Predicate::Arg` with `type` (Capture/String) and `value : String`.
- `[x]` `Query#capture_name_for_id` and `Query#string_value_for_id` public accessors.
- `[x]` 15 TDD specs, all passing in fork and host project.
- `[x]` Host project `shard.yml` pointing to `branch: feat/query-predicate-processing`.

#### P7.2: PredicateEvaluator Module — Implemented

Implementation:

- `src/chiasmus/discovery/predicate_evaluator.cr` — `PredicateEvaluator` module with:
  - `evaluate_match_predicates` — evaluates all predicates for a query match, populates metadata/adjacent hashes.
  - Filter predicates: `eval_eq?`, `eval_not_eq?`, `eval_match?`, `eval_not_match?`.
  - Node-type predicates: `eval_has_type?`, `eval_has_parent?`, `eval_not_has_parent?`.
  - Metadata predicates: `eval_set!`, `eval_select_adjacent!`, `eval_lineage_from_name!`, `eval_strip!`.
  - Helpers: `doc_text`, `capture_text`, `capture_node`.

Deliverables:

- `[x]` All 11 codeium-parse predicate types implemented.
- `[x]` `#set!` sets key-value metadata on captures.
- `[x]` `#select-adjacent!` collects adjacent previous-sibling nodes.
- `[x]` `#lineage-from-name!` parses delimiter-based lineage paths.
- `[x]` `#strip!` strips characters from capture text.
- `[x]` `#match?` / `#not-match?` regex evaluation with rescue for invalid patterns.

#### P7.3: QueryExtractor Predicate Integration — Implemented

Implementation:

- `src/chiasmus/discovery/extractor.cr` — `QueryExtractor` extended with:
  - `predicate_queries` virtual method (default empty hash) for codeium-parse-style queries.
  - `process_predicate_query` — runs query with `PredicateEvaluator.evaluate_match_predicates`, extracts `@name`, `@doc`, `@codeium.parameters`, `@codeium.return_type` captures.
  - `extract_name_from_match` — resolves name from match captures.
- Backward-compatible: existing `queries` method unchanged.

Deliverables:

- `[x]` `predicate_queries` method with default empty return.
- `[x]` Predicate-aware match processing in `extract`.
- `[x]` Doc, params, return_type capture extraction.
- `[x]` Non-fatal query error handling.

#### P7.4: Enhanced Extractors With Codeium-Parse Queries — Implemented (7/9 extractors)

Implementation:

Enriched `predicate_queries` for each language with missing codeium-parse features:

| Language | New Kinds Added |
|----------|----------------|
| **Go** | `package`, `definition.type`, `reference.call`, `reference.call_sel`, `reference.class`, enriched `definition.function` (doc+params+return_type), enriched `definition.method` (doc+params+return_type) |
| **Java** | `package`, `definition.constructor`, enriched `definition.method` (doc+params) |
| **JavaScript** | `definition.constructor`, `definition.import`, `reference.call`, `reference.call_sel`, `reference.class` |
| **Python** | `definition.constructor`, `definition.import`, `reference.call`, `reference.call_attr` |
| **Ruby** | `definition.module`, `definition.import`, `reference.call`, `reference.call_sel` |
| **TypeScript** | `definition.module`, `definition.namespace`, `definition.constructor`, `definition.import`, `reference.call`, `reference.call_sel`, `reference.class` |
| **Crystal** | `definition.import` (require), `definition.module` (include/extend), `reference.call_sel` (dot calls), `reference.call` (bare calls), `reference.class` (Foo.new), `reference.call_op` (operators), `reference.call_imp` (&.method), `reference.call_idx` (obj[key]) |

Deliverables:

- `[x]` Go: 7 predicate query patterns.
- `[x]` Java: 3 predicate query patterns.
- `[x]` JavaScript: 6 predicate query patterns.
- `[x]` Python: 4 predicate query patterns.
- `[x]` Ruby: 4 predicate query patterns.
- `[x]` TypeScript: 7 predicate query patterns.
- `[x]` Crystal: 8 predicate query patterns (no upstream codeium-parse — written from grammar analysis).

#### P7.5: Remaining Extractors — Implemented

**Goal:** add extractors for languages codeium-parse covers but we don't yet.

Implementation:

- Added 9 grammar submodules (`vendor/grammars/tree-sitter-{lang}/`) for bash, c, cpp, c-sharp, dart, kotlin, perl, php, proto.
- Compiled shared libraries via `scripts/compile_new_grammars.cr` (handles cpp npm dep, php subdirectory, proto ABI 14, csharp hyphenated naming).
- Created 9 `QueryExtractor` subclasses in `src/chiasmus/discovery/extractors/`:

| Language | Extractor | Kinds covered |
|----------|-----------|---------------|
| bash | `BashExtractor` | `function` |
| c | `CExtractor` | `function`, `definition.import` |
| cpp | `CppExtractor` | `class`, `function`, `interface`, `definition.namespace`, `field` |
| csharp | `CSharpExtractor` | `class`, `interface`, `method`, `definition.namespace`, `definition.class` (struct/record), `definition.enum`, `definition.constructor`, `definition.destructor` |
| dart | `DartExtractor` | `class`, `function` |
| kotlin | `KotlinExtractor` | `class`, `function`, `definition.constructor`, `definition.import` |
| perl | `PerlExtractor` | `class`, `function`, `definition.import` |
| php | `PhpExtractor` | `class`, `interface`, `function`, `method`, `definition.namespace` |
| protobuf | `ProtobufExtractor` | `class` (message/enum/service), `function` (rpc), `definition.package`, `field` |

- Updated `grammar_batch_operations.cr`, `setup_grammars.cr`, and `Makefile` dist target for all 19 languages.
- Fixed `grammar_loader.cr` for csharp symbol (`tree_sitter_c_sharp`) and directory (`tree-sitter-c-sharp`) naming.
- Active golden specs: 15/15 languages pass (csharp working after loader fix).

Deliverables:

- `[x]` 9 grammar submodules added and compiled.
- `[x]` 9 new extractor implementations with query patterns.
- `[x]` CLI batch ops, setup script, and Makefile updated for 19 languages.
- `[x]` csharp grammar loader fix (symbol + directory naming).

#### P7.6: Class Fields Extraction — Implemented

Languages with field extraction (all grammars now vendored and compiled):
- `[x]` go — `field_declaration` capture (struct fields)
- `[x]` java — `field_declaration` + `formal_parameter` capture
- `[x]` javascript — `field_definition` capture
- `[x]` python — `assignment` capture in class body
- `[x]` typescript — `public_field_definition` + `property_signature` capture
- `[x]` cpp — `field_declaration_list` capture in class/struct specifier
- `[x]` c — field declarations via struct_specifier (same query as cpp)
- `[x]` protobuf — `message_body` / `enum_body` field captures

#### P7.7: Codeium-Parse Golden Output Parity — Implemented

**Goal:** verify that enhanced extractor output matches codeium-parse golden files.

Implementation:

- `spec/chiasmus/discovery/codeium_parse_golden_spec.cr` — 15 golden specs using `dsisnero/golden` shard.
- Golden files in `spec/testdata/codeium_parse/` for all 15 languages with extractors.
- Each spec parses the corresponding codeium-parse test file, runs the extractor, and compares sorted `kind: name` output.
- Golden update via `GOLDEN_UPDATE=1 crystal spec ...`.
- Fixed pre-existing `Platform.shared_library_extension` bug in `grammar_loader.cr`.
- Fixed Python class fields query to match actual tree-sitter grammar.
- Fixed csharp grammar loader (symbol `c_sharp`, directory `c-sharp` naming).

Deliverables:

- `[x]` 15 golden output parity specs covering all codeium-parse test files with extractors.
- `[x]` Golden reference data for 15 languages.
- `[x]` Crystal-native `Golden.require_equal` comparison with update support.

#### P7: Acceptance

- `[x]` Predicate parsing infrastructure in tree-sitter shard (15 specs).
- `[x]` `PredicateEvaluator` module handling all 11 codeium-parse predicate types.
- `[x]` `QueryExtractor` base class supports `predicate_queries` with predicate evaluation.
- `[x]` All 16 extractors implemented with predicate queries (7 enhanced + 9 new).
- `[x]` Class fields extraction for 8 languages (go, java, js, python, ts, c, cpp, protobuf).
- `[x]` Golden output parity: 15 specs, golden files for all languages.
- `[x]` 9 grammar submodules vendored and compiled (19 total grammars).
- `[x]` CLI batch ops, setup script, Makefile updated for 19 languages.
- `[x]` csharp grammar loader fix (symbol + directory naming).
- `[x]` All quality gates: format clean, lint 107 files/0 failures, spec 573 passing, 1 API-key pending.
- `[x]` `docs/development.md` with language-adding guide and 18-language inventory.
- `[x]` Crystal shard PR merged to main branch (dsisnero/crystal-tree-sitter#1).

### P6: Release Hardening — Completed

**Goal:** make the port reliable as a user-facing shard/CLI/server.

Results:

- `crystal tool format --check src spec` — clean, no formatting violations.
- `bin/ameba src spec` — 107 files inspected, 0 failures.
- `crystal spec` — 573 examples, 0 failures, 0 errors, 1 pending (requires DEEPSEEK_API_KEY).
- `._*` AppleDouble sidecars cleaned from working tree.
- `spec/tmp_cr_*.cr` scratch specs confirmed untracked (gitignored), kept local only.
- Inventory manifests: `typescript_port_inventory.tsv` (505 items), `typescript_source_parity.tsv`, `typescript_test_parity.tsv` — all clean.
- Conversion rules: 18 rules across 6 subsystems in `conversion_rules.tsv`.
- Prolog facts: 2,073 facts in `parity_facts.pl` with example queries.
- Intentional divergences: 37 documented items with crystal_refs and rationale notes.

Remaining intentional divergences explained:
- **Crig** replaces all upstream LLM adapters (Anthropic, OpenAI-compatible, mock) — 12 divergences.
- **crolog/SWI-Prolog** replaces Tau Prolog — 5 divergences.
- **bm25** Crystal shard replaces upstream BM25 — 5 divergences.
- **Manifest discovery** replaces Node.js dynamic module loading — 2 divergences.
- **tree_sitter** shard replaces upstream getNativeParser — 1 divergence.
- **Clojure WASM parser** deferred; source-form extractor used — 3 divergences.
- **Z3 solver** constructor config replaces global timeout constant — 1 divergence.

Acceptance:

- `[x]` `make format`, `make lint`, and `make test` pass.
- `[x]` Inventory checks pass.
- `[x]` Release notes can explain remaining intentional divergences without ambiguity.

## Implementation History (All Completed)

1. **P0 Vendor Refresh And Change Impact Tracking** — Implemented.
2. **P1 Dynamic Adapter Discovery** — Implemented.
3. **P2 Clojure Tree-Sitter Runtime Support** — Implemented with parser divergence.
4. **P3 Tree-Sitter Discovery And Inventory Quality** — Implemented.
5. **P3.1 Multi-Language Core Abstractions** — Implemented.
6. **P3.2 Remaining Languages + CLI Integration** — Implemented.
7. **P4 Prolog Fact Inventory And Conversion Rules** — Implemented.
8. **P5 MCP Transport-Level Harness** — Implemented.
9. **P6 Release Hardening** — Implemented.
10. **P7 Codeium-Parse Predicate Support** — Implemented (P7.1-P7.7 complete)

## Current Completion Criteria

- `[x]` No tracked inventory rows are `missing`.
- `[x]` No tracked inventory rows are `partial`.
- `[x]` Core MCP verify behavior, including Prolog batch queries, is ported.
- `[x]` Graph/session/solver behavior has direct Crystal specs.
- `[x]` Vendor pull drift can identify changed same-ID upstream items.
- `[x]` Node.js dynamic adapter discovery is an intentional divergence; Crystal adapters are compiled and registered explicitly.
- `[x]` Clojure runtime parser behavior is executable or explicitly deferred with parser-independent coverage.
- `[x]` Inventory can be exported to Prolog facts for conversion-rule audits (P4).
- `[x]` Tree-sitter-backed discovery for TypeScript with regex fallback and parser mode reporting (P3).
- `[x]` Multi-language discovery for 19 languages with SOLID abstractions (P3.1/P3.2/P7.5).
- `[x]` Non-blocking pipeline with fiber-per-file concurrency (P3.1).
- `[x]` MCP transport-level harness with in-memory transport specs (P5).
- `[x]` 573 specs, 0 failures. Format + lint clean. (P6/P7 updated).
- `[x]` Conversion rules and Prolog facts make intentional divergences queryable by subsystem (P4).
- `[x]` Tree-sitter shard patched with `Query#predicates_for_pattern` and `Predicate` types (P7.1).
- `[x]` `PredicateEvaluator` module handling all 11 codeium-parse predicate types (P7.2).
- `[x]` All 16 extractors enhanced/created with codeium-parse predicate queries (P7.3, P7.4, P7.5).
- `[x]` Class fields extraction for 8 languages (P7.6).
- `[x]` Golden output parity: 15 specs, golden files for all extractor languages (P7.7).
- `[x]` 9 grammar submodules vendored, compiled, and integrated into CLI/Makefile.
- `[x]` `docs/development.md` with language-adding guide and grammar inventory.
- `[x]` Crystal shard PR merged to main branch.

## Parity Plan Current State

P0-P21, P23 complete. 1204 specs, 0 failures. Lint 0 failures, format clean. The port is in parity maintenance.

## MCP Tools Feature Matrix

All 11 upstream MCP tools are ported. Crystal adds 1 extra tool (`chiasmus_crig`).

| Tool | Upstream | Crystal | Source | Specs | Transport | Status |
|---|---|---|---|---|---|---|
| `chiasmus_verify` | ✓ | ✓ | `tools/verify.cr` | 14 | ✓ | Complete |
| `chiasmus_skills` | ✓ | ✓ | `tools/skills.cr` | 7 | — | Complete |
| `chiasmus_formalize` | ✓ | ✓ | `tools/formalize.cr` | 6 | — | Complete |
| `chiasmus_solve` | ✓ | ✓ | `tools/solve.cr` | 4 | — | Complete |
| `chiasmus_learn` | ✓ | ✓ | `tools/learn.cr` | 8 | — | Complete |
| `chiasmus_lint` | ✓ | ✓ | `tools/lint.cr` | 10 | — | Complete |
| `chiasmus_graph` | ✓ | ✓ | `tools/graph.cr` | 26 | ✓ | Complete |
| `chiasmus_map` | ✓ | ✓ | `tools/map.cr` | 0 | — | Complete |
| `chiasmus_search` | ✓ | ✓ | `tools/search.cr` | 7 | — | Complete |
| `chiasmus_craft` | ✓ | ✓ | `tools/craft.cr` | 12 | — | Complete |
| `chiasmus_review` | ✓ | ✓ | `tools/review.cr` | 0 | — | Complete |
| `chiasmus_crig` | — | ✓ | `tools/crig.cr` | 2 | — | Crystal-only |

**Legend:** Transport = MCP transport-level spec (in-memory harness). `—` = not yet wired (requires `MCPServer.current_server` mock).

## CLI/Targets Feature Matrix

| Binary | Upstream (npm) | Crystal | Source | Description |
|---|---|---|---|---|
| `chiasmus` | `npx chiasmus` (MCP server) | `bin/chiasmus` | `src/chiasmus.cr` | MCP stdio server entry point |
| `chiasmus-agent` | — | `bin/chiasmus-agent` | `src/chiasmus-agent.cr` | Crystal-only: interactive agent CLI |
| `chiasmus-grammar` | — | `bin/chiasmus-grammar` | `src/chiasmus_grammar.cr` | Tree-sitter grammar discovery + compilation |
| `chiasmus-discover` | — | `bin/chiasmus-discover` | `src/chiasmus_discover.cr` | Multi-language symbol discovery CLI |

## Graph Analyses Feature Matrix

Upstream exposes 16 graph analyses via `chiasmus_graph`. All ported.

| Analysis | Upstream | Crystal `analyses.cr` | Specs |
|---|---|---|---|
| `summary` | ✓ | ✓ | `analyses_spec.cr` |
| `callers` | ✓ | ✓ | ✓ |
| `callees` | ✓ | ✓ | ✓ |
| `reachability` | ✓ | ✓ | ✓ |
| `path` | ✓ | ✓ | ✓ |
| `impact` | ✓ | ✓ | ✓ |
| `dead-code` | ✓ | ✓ | ✓ |
| `cycles` | ✓ | ✓ | ✓ |
| `facts` | ✓ | ✓ | ✓ |
| `layer-violation` | ✓ | ✓ | `layer_violation_spec.cr` |
| `hubs` | ✓ | ✓ | `hubs_spec.cr`, `insights_spec.cr` |
| `bridges` | ✓ | ✓ | `insights_spec.cr` |
| `surprises` | ✓ | ✓ | `insights_spec.cr` |
| `communities` | ✓ | ✓ | `community_spec.cr` |
| `diff` | ✓ | ✓ | `diff_snapshot_spec.cr`, `graph_diff_spec.cr` |
| `entry-points` | ✓ | ✓ | `entry_points_spec.cr` |

**Note:** All 16 analyses fully wired and tested.

## Discovery Extractor Language Coverage

All 19 languages covered by upstream codeium-parse + Crystal extractor have working tree-sitter extractors.

| Language | Extractor | Kinds | Golden Test |
|---|---|---|---|
| bash | `BashExtractor` | function | ✓ |
| c | `CExtractor` | function, definition.import | ✓ |
| cpp | `CppExtractor` | class, function, interface, namespace, field | ✓ |
| csharp | `CSharpExtractor` | class, interface, method, namespace, enum, constructor, destructor | ✓ |
| crystal | `CrystalExtractor` | class, interface, enum, type, method, macro, const, lib, function, annotation, field, import, module, call_sel, call, class_ref, call_op, call_imp, call_idx | ✓ |
| dart | `DartExtractor` | class, function | ✓ |
| go | `GoExtractor` | class, interface, function, method, test, type, package, field, enriched fn/method | ✓ |
| java | `JavaExtractor` | class, enum, interface, function, method, const, constructor, package, field, enriched method | ✓ |
| javascript | `JavaScriptExtractor` | class, interface, function, method, type, const, test, constructor, import, call, call_sel, class_ref, field | ✓ |
| kotlin | `KotlinExtractor` | class, function, constructor, import | ✓ |
| perl | `PerlExtractor` | class, function, import | ✓ |
| php | `PhpExtractor` | class, interface, function, method, namespace | ✓ |
| protobuf | `ProtobufExtractor` | class, function, package, field | ✓ |
| python | `PythonExtractor` | class, interface, function, method, constructor, import, call, call_attr, field | ✓ |
| ruby | `RubyExtractor` | class, interface, method, module, import, call, call_sel | ✓ |
| rust | `RustExtractor` | class, interface, function, method, const | ✓ |
| scala | `ScalaExtractor` | class, interface, function | ✓ |
| typescript | `TypeScriptExtractor` | class, interface, function, method, type, const, test, module, namespace, constructor, import, call, call_sel, class_ref, field | ✓ |
| tsx | `TSXExtractor` | (delegates to TypeScript) | ✓ |

## Graph Walker Language Coverage

Per-language AST walkers for the `extract_graph` pipeline:

| Language | Walker File | Status |
|---|---|---|
| typescript | `walkers/javascript.cr` (generic `walk_node`) | Implemented |
| javascript | `walkers/javascript.cr` (generic `walk_node`) | Implemented |
| python | `walkers/python.cr` | Implemented |
| go | `walkers/go.cr` | Implemented |
| rust | `walkers/rust.cr` | Implemented (matched upstream 07bbf4a) |
| crystal | `walkers/crystal.cr` | Implemented |
| java | `walkers/java.cr` | Implemented |
| clojure | `walkers/clojure.cr` + `ClojureSourceExtractor` | Implemented (WASM parser divergence) |
| csharp | `walkers/csharp.cr` | Implemented (Crystal-native) |

### P18: Diff/Snapshot Analysis Wiring — Fixes Needed (2026-06-14)

**Goal:** complete the `save_snapshot` + `diff`/`against` wiring that P18 declared complete but left with three gaps.

**Problem:** `chiasmus_graph` snapshot save/load worked at the `GraphCache` level (cache.cr) but was never wired into the MCP tool handler. The `input_schema` didn't expose `cache` or `saveSnapshot`. Calling `chiasmus_graph(analysis="diff", against="baseline")` always returned `"diff requires a cache directory to load snapshots"` because `snapshot_cache_dir` was nil.

**Root cause:** Three missing pieces in the port:

| # | File | Missing | Upstream reference |
|---|------|---------|-------------------|
| 1 | `src/chiasmus/mcp_server/types.cr:421` | `GraphInput.saveSnapshot : String?` field | `analyses.ts:84` — `saveSnapshot?: string` |
| 2 | `src/chiasmus/mcp_server/tools/graph.cr:82-95` | `input_schema` missing `cache` and `save_snapshot` properties | `analyses.ts:80,84` — `cache?: CacheOptions` and `saveSnapshot?: string` |
| 3 | `src/chiasmus/graph/analyses.cr:145` | `graph.cr:33` passes `args.cache` but `run_analysis` never calls `GraphCache.save_snapshot()` after extraction | `analyses.ts:161-175` — calls `saveSnapshot(request.saveSnapshot, graph, request.cache)` |

**Upstream behavior** (`vendor/chiasmus/src/graph/analyses.ts:106-179`):

1. `runAnalysis(filePaths, request)` accepts `request.saveSnapshot?: string` and `request.cache?: CacheOptions`
2. After `extractGraph()` → if `request.saveSnapshot` is set AND `request.cache` is provided → `saveSnapshot(request.saveSnapshot, graph, request.cache)`
3. Guard: if `saveSnapshot == against` AND `analysis == "diff"` → reject with error (save would clobber baseline before diff)
4. Without `cache`, `saveSnapshot` produces a warning, not an error (graceful degradation)

**Fix plan (TDD):**

| Step | Test | Implementation |
|------|------|---------------|
| 1 | Red: `graph_diff_spec.cr` — test that diff with no cache returns meaningful error | Existing |
| 2 | Red: `graph tool` — pass `cache`+`saveSnapshot` → verify snapshot file exists on disk | New |
| 3 | Red: `graph tool` — pass `cache`+`against` → diff against saved snapshot works | New |
| 4 | Red: `graph tool` — pass `saveSnapshot==against` with analysis=`diff` → returns guard error | New |
| 5 | Green: add `saveSnapshot` to `GraphInput` | `types.cr:421` |
| 6 | Green: add `cache` and `saveSnapshot` to `input_schema` | `graph.cr:82` |
| 7 | Green: wire `save_snapshot` call in `run_analysis` | `analyses.cr:145` |
| 8 | Green: guard `saveSnapshot == against` for diff | `analyses.cr:145` |
| 9 | Refactor: verify all 16 analyses still pass downstream in chiasmus.cr | 1138 specs |

**Files to change:**
- `src/chiasmus/mcp_server/types.cr` — add `saveSnapshot` to `GraphInput`
- `src/chiasmus/mcp_server/tools/graph.cr` — add `cache`/`saveSnapshot` to `input_schema`, pass `saveSnapshot`
- `src/chiasmus/graph/analyses.cr` — wire `save_snapshot` call, guard same-name rejection
- `spec/chiasmus/graph/graph_diff_spec.cr` — TDD:
  - diff returns error without cache dir
  - diff returns error when snapshot not found
  - save + load round-trip works
  - save + diff against same snapshot is rejected
  - save then diff against saved snapshot succeeds

**Acceptance:**
- `[ ]` `save_snapshot="baseline"` with `cache="/tmp/cache"` creates `<cache>/default/snapshots/baseline.json`
- `[ ]` `analysis="diff"` + `against="baseline"` + `cache="/tmp/cache"` returns diff result
- `[ ]` `saveSnapshot="x"` + `against="x"` + `analysis="diff"` returns guard error
- `[ ]` All existing graph tests still pass
- `[ ]` 1138 chiasmus specs pass

## Maintenance Mode Runbook

### After `git submodule update --remote vendor/chiasmus`

```bash
SKILL_DIR="${CHIASMUS_PARITY_SKILL_DIR:-$HOME/.agents/skills/crystal_forge/skills/cross-language-crystal-parity}"

# 1. Materialize the current fact/planning bundle
"${SKILL_DIR}/scripts/plan_with_chiasmus.sh" . vendor/chiasmus typescript src
# Review plans/generated/parity/typescript/parity_summary.txt for match-status and drift counts

# 2. Run drift checks
"${SKILL_DIR}/scripts/check_port_inventory.sh" . plans/inventory/typescript_port_inventory.tsv vendor/chiasmus typescript
"${SKILL_DIR}/scripts/check_source_parity.sh" . plans/inventory/typescript_source_parity.tsv vendor/chiasmus typescript
"${SKILL_DIR}/scripts/check_test_parity.sh" . plans/inventory/typescript_test_parity.tsv vendor/chiasmus typescript

# 3. Run the fact-driven completion gate
"${SKILL_DIR}/scripts/check_completion_gate.sh" . plans/inventory/typescript_port_inventory.tsv vendor/chiasmus typescript src
"${SKILL_DIR}/scripts/check_completion_gate.sh" . plans/inventory/typescript_port_inventory.tsv vendor/chiasmus typescript src --query incomplete --format ids

# 4. Regenerate Prolog facts only if you still need ledger-only queries
ruby "${SKILL_DIR}/scripts/generate_inventory_facts.rb" \
  --inventory plans/inventory/typescript_port_inventory.tsv \
  --source plans/inventory/typescript_source_parity.tsv \
  --tests plans/inventory/typescript_test_parity.tsv \
  --rules plans/inventory/conversion_rules.tsv \
  > plans/inventory/parity_facts.pl

# 5. Run quality gates and adversarial signoff
make format && make test
"${SKILL_DIR}/scripts/verify_parity_adversarial.sh" . vendor/chiasmus typescript 'make test' '<upstream test command>'
```

### Drift Response

| Drift report | Action |
|---|---|
| `added` | Run `sync_port_inventory.rb`, then curate status/refs for the new source rows |
| `removed` | Remove stale row from inventory |
| `changed` | Review Crystal port for behavior update |
| `context_changed` | Low risk; review for new edge cases |
| Intentional divergence area changed | Review Crystal replacement subsystem |

### Inventory Invariants

- No tracked row has status `missing` or `partial`
- Every `ported`/`partial` row has non-empty `crystal_refs`
- `typescript_port_inventory.tsv` is the curated ledger — never auto-regenerated
- The curated ledger is source-focused; exhaustive test drift belongs in `typescript_test_parity.tsv`
- Legacy ledgers may stay on the 5-column format; new ledgers may use a
  header-driven schema with explicit `target_symbol` and `test_refs` columns so
  symbol mapping and test coverage do not have to hide in free-form `notes`
- `ruby scripts/upgrade_port_inventory.rb --input plans/inventory/typescript_port_inventory.tsv --in-place`
  is the supported migration path from legacy 5-column ledgers to the richer
  header-driven format
