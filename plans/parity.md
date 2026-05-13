# Chiasmus Crystal Parity Plan

## Current Inventory State

The TypeScript upstream inventory is now fully accounted for at the row level.

| Manifest | Tracked | Ported | Intentional divergence | Missing | Partial |
|---|---:|---:|---:|---:|---:|
| `typescript_source_parity.tsv` | 173 | 139 | 34 | 0 | 0 |
| `typescript_test_parity.tsv` | 332 | 329 | 3 | 0 | 0 |
| `typescript_port_inventory.tsv` | 505 | 468 | 37 | 0 | 0 |

Interpretation:

- There are no currently tracked upstream rows left as `missing` or `partial` in any manifest.
- Remaining divergence rows are deliberate runtime substitutions (Crig, crolog/SWI-Prolog, BM25, manifest discovery, Clojure WASM parser, Z3 config).
- Future work is in maintenance mode: run drift checks after vendor pulls, review changed upstream items, and update conversion rules as needed.

## Inventory Safety And Vendor Updates

The inventory workflow is safe for user/agent updates as long as we keep the curated/generated split:

- Curated ledger: `plans/inventory/typescript_port_inventory.tsv`
- Generated/drift snapshots: `plans/inventory/typescript_source_parity.tsv`, `plans/inventory/typescript_test_parity.tsv`
- Do not regenerate the curated ledger over existing work.
- Use check scripts to detect new/stale IDs after vendor pulls.

Current drift checks catch:

- New upstream API/test IDs that are not in inventory.
- Removed/renamed upstream IDs that are stale in inventory.
- Invalid statuses.
- `ported`/`partial` rows missing Crystal references.

Current drift checks do not fully catch:

- Behavior changes inside an upstream function/test whose discovered ID stayed the same.
- Semantic changes in fixtures, prompt text, solver rules, or tree-sitter walker logic.
- Changes to intentionally divergent upstream areas that may require Crystal replacement updates.

Priority feature for vendor refreshes:

1. Add an upstream change-impact manifest that records content fingerprints per source/test item.
2. On `vendor/chiasmus` update, diff old/new fingerprints and mark impacted port rows for review.
3. Generate a queryable Prolog fact file so changed upstream items can be grouped by feature area and replacement rule.
4. Make this workflow non-destructive: it should only add/update a separate drift report, never overwrite curated inventory statuses.

## Large Feature Priority

### P0: Vendor Refresh And Change Impact Tracking — Implemented

**Goal:** make upstream pulls safe and actionable.

Why this is first:

- Row-level inventory is clean, so the biggest future risk is silent upstream behavior drift.
- The current scripts can say "IDs match", but not "this function/test changed internally".
- This enables large-feature planning after every upstream pull.

Implemented deliverables:

- `scripts/generate_upstream_fingerprints.rb`
- `scripts/compare_upstream_fingerprints.rb`
- `plans/inventory/typescript_upstream_fingerprints.tsv`
- `plans/inventory/typescript_upstream_drift.tsv`
- `spec/scripts/upstream_fingerprints_spec.cr`

Current workflow:

```bash
ruby scripts/generate_upstream_fingerprints.rb \
  --root . \
  --source vendor/chiasmus \
  --language typescript \
  --out /tmp/chiasmus-new-fingerprints.tsv

ruby scripts/compare_upstream_fingerprints.rb \
  --old plans/inventory/typescript_upstream_fingerprints.tsv \
  --new /tmp/chiasmus-new-fingerprints.tsv \
  --out plans/inventory/typescript_upstream_drift.tsv
```

Change report types:

- `added` — upstream added a newly discoverable item.
- `removed` — upstream removed or renamed a tracked item.
- `changed` — same discovered ID, extracted item fingerprint changed.
- `context_changed` — same item fingerprint, but surrounding file changed.

Acceptance:

- `[x]` Pulling `vendor/chiasmus` can produce a review list without overwriting user/agent inventory edits.
- `[x]` New IDs, stale IDs, and changed same-ID bodies are visible.
- `[x]` The report distinguishes direct item changes from surrounding file context changes.
- `[x]` Prolog fact export for changed items delivered in P4.

### P1: Dynamic Adapter Discovery — Implemented

**Goal:** replace the current explicit-registration-only model with a Crystal-native discovery mechanism.

Inventory drivers:

- `src/graph/adapter-registry.ts::function::registerFromModule`
- `src/graph/adapter-registry.ts::function::isLanguageAdapter`

Current status:

- Explicit adapter registration is ported and tested.
- Node module-based dynamic loading remains an `intentional_divergence`.
- The user-facing discoverability gap is closed with Crystal-native manifest discovery and registered adapter factories.

Implemented design:

- `chiasmus.adapters.json` manifests declare adapter language, extensions, grammar language, factory entrypoint, and optional search paths.
- `AdapterFactory` provides the dependency-injected construction boundary for adapters compiled into the Crystal process.
- Discovery is idempotent and non-throwing.
- Invalid descriptors and missing factories are skipped with diagnostics instead of crashing the graph tool.
- Discovered adapters can point at additional manifest directories via `search_paths`, preserving the useful part of upstream `searchPaths`.

Deliverables:

- `[x]` Discovery interface separated from registry mutation.
- `[x]` Manifest parser with validation.
- `[x]` Specs for idempotency, invalid descriptors, search paths, and precedence vs built-ins.
- `[x]` Inventory notes updated from "explicit only" to the chosen Crystal discovery model.

Acceptance:

- `[x]` A project can add an adapter without editing core registry code by registering an adapter factory and shipping a manifest.
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
- `scripts/parity_inventory_lib.rb` — Updated to delegate to the Crystal discovery binary when `PORT_PARSER=tree-sitter` or `--parser tree-sitter` is requested.
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

- `[x]` All 19 languages have working tree-sitter extractors with TDD/golden specs (526 total).
- `[x]` Pipeline processes files concurrently with bounded parallelism.
- `[x]` SOLID: new language = new `QueryExtractor` subclass, no Pipeline/Registry changes.
- `[x]` Format + ameba lint clean.

### P4: Prolog Fact Inventory And Conversion Rules — Implemented

**Goal:** make parity status and conversion rules queryable.

Why this matters:

- Chiasmus has several intentional replacement layers: Crig for LLMs, crolog/SWI-Prolog for Tau Prolog, BM25 shard for upstream BM25, and Crystal-specific adapter discovery.
- These are easier to audit as facts than as prose scattered across inventory notes.

Implementation:

- `plans/inventory/conversion_rules.tsv` — 18 conversion rules mapping upstream TypeScript patterns to Crystal replacements across 6 subsystems (LLM adapters, Prolog, BM25, adapter discovery, tree-sitter, Z3).
- `scripts/generate_inventory_facts.rb` — Deterministic Ruby script that reads port inventory, source parity, test parity, and conversion rules to produce Prolog facts.
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
- `spec/scripts/inventory_facts_spec.cr` — 5 specs: fact generation, status filtering, conversion rule independence, deterministic output, and non-destructive behavior.
- `scripts/generate_inventory_facts.rb` avoids newer Ruby-only APIs so the parity fact generator runs under the same Ruby available to the Crystal spec harness.

Deliverables:

- `[x]` `plans/inventory/conversion_rules.tsv` with 18 mapping rules across 6 subsystems.
- `[x]` `scripts/generate_inventory_facts.rb` for deterministic fact generation.
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

### P7: Codeium-Parse Predicate Support — In Progress

**Goal:** port codeium-parse custom query predicate handling and enhance extractors with enriched captures (doc, params, return_type, lineage, references).

Inventory drivers:

- Vendored `vendor/codeium-parse/queries/*.scm` (19 language query files with custom predicates).
- Vendored `vendor/codeium-parse/goldens/*.golden` (expected output format for 17 languages).
- Existing extractors lack doc comments, parameters, return types, lineage metadata, and call/class references.

Design document: `plans/design/codeium_parse_predicates.md` (to be created)

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
- Active golden specs: 14/15 languages pass (csharp working after loader fix).

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
- `[x]` All quality gates: format clean, lint 107 files/0 failures, spec 526 passing.
- `[x]` `docs/development.md` with language-adding guide and 18-language inventory.
- `[x]` Crystal shard PR merged to main branch (dsisnero/crystal-tree-sitter#1).

### P6: Release Hardening — Completed

**Goal:** make the port reliable as a user-facing shard/CLI/server.

Results:

- `crystal tool format --check src spec` — clean, no formatting violations.
- `bin/ameba src spec` — 107 files inspected, 0 failures.
- `crystal spec` — 526 examples, 0 failures, 0 errors, 1 pending (requires DEEPSEEK_API_KEY).
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
- `[x]` Crystal-native dynamic adapter discovery exists.
- `[x]` Clojure runtime parser behavior is executable or explicitly deferred with parser-independent coverage.
- `[x]` Inventory can be exported to Prolog facts for conversion-rule audits (P4).
- `[x]` Tree-sitter-backed discovery for TypeScript with regex fallback and parser mode reporting (P3).
- `[x]` Multi-language discovery for 19 languages with SOLID abstractions (P3.1/P3.2/P7.5).
- `[x]` Non-blocking pipeline with fiber-per-file concurrency (P3.1).
- `[x]` MCP transport-level harness with in-memory transport specs (P5).
- `[x]` 526 specs, 0 failures. Format + lint clean. (P6 updated).
- `[x]` Conversion rules and Prolog facts make intentional divergences queryable by subsystem (P4).
- `[x]` Tree-sitter shard patched with `Query#predicates_for_pattern` and `Predicate` types (P7.1).
- `[x]` `PredicateEvaluator` module handling all 11 codeium-parse predicate types (P7.2).
- `[x]` All 16 extractors enhanced/created with codeium-parse predicate queries (P7.3, P7.4, P7.5).
- `[x]` Class fields extraction for 8 languages (P7.6).
- `[x]` Golden output parity: 15 specs, golden files for all extractor languages (P7.7).
- `[x]` 9 grammar submodules vendored, compiled, and integrated into CLI/Makefile.
- `[x]` `docs/development.md` with language-adding guide and grammar inventory.
- `[ ]` Crystal shard PR merged to main branch.

## Parity Plan Complete

P0-P7 are complete. The port is in stable maintenance.

See `plans/tool_parity.md` for MCP tool parity tracking (spec gaps, transport integration).

## Maintenance Mode

The port is in stable maintenance. Operational runbook after upstream vendor pulls:

### After `git submodule update --remote vendor/chiasmus`

```bash
# 1. Run drift checks
./scripts/check_port_inventory.sh . plans/inventory/typescript_port_inventory.tsv vendor/chiasmus typescript
./scripts/check_source_parity.sh . plans/inventory/typescript_source_parity.tsv vendor/chiasmus typescript
./scripts/check_test_parity.sh . plans/inventory/typescript_test_parity.tsv vendor/chiasmus typescript

# 2. Compare upstream fingerprints for behavioral drift
ruby scripts/generate_upstream_fingerprints.rb \
  --root . --source vendor/chiasmus --language typescript \
  --out /tmp/chiasmus-new-fingerprints.tsv

ruby scripts/compare_upstream_fingerprints.rb \
  --old plans/inventory/typescript_upstream_fingerprints.tsv \
  --new /tmp/chiasmus-new-fingerprints.tsv \
  --out plans/inventory/typescript_upstream_drift.tsv

# 3. Regenerate Prolog facts if inventory changed
ruby scripts/generate_inventory_facts.rb \
  --inventory plans/inventory/typescript_port_inventory.tsv \
  --source plans/inventory/typescript_source_parity.tsv \
  --tests plans/inventory/typescript_test_parity.tsv \
  --rules plans/inventory/conversion_rules.tsv \
  > plans/inventory/parity_facts.pl

# 4. Run quality gates
make format && make lint && make test
```

### Response to change types

| Drift report | Action |
|---|---|
| `added` | Add new row to `typescript_port_inventory.tsv` with status `missing`, file backlog issue |
| `removed` | Remove stale row from inventory (ID no longer valid) |
| `changed` | Review Crystal port for behavior update; update `crystal_refs` and status if needed |
| `context_changed` | Low risk; review if surrounding code suggests new edge case |
| Intentional divergence area changed | Review Crystal replacement subsystem for parity gap |

### Static inventory invariants (verify after any edit)

- No tracked row has status `missing` or `partial`
- Every `ported`/`partial` row has non-empty `crystal_refs`
- `typescript_port_inventory.tsv` is the curated ledger — never auto-regenerated over existing work
