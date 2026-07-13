# Dead-code audit

Date: 2026-07-12

Implementation status: **R1, R2, and R3 removed on 2026-07-12.** The audit and
execution notes below are retained as the rationale for the deletions.

## Scope and conclusion

`chiasmus_graph analysis=dead-code` was run over all 149 Crystal files under
`src/`. It returned 137 names. That output is a candidate generator, not a
deletion list: the analysis does not model Crystal's overloads accurately, does
not see shard consumers, and does not treat specs, binary targets, callbacks,
MCP dispatch, JSON hooks, or interface implementations as roots.

The audit compared the candidates with:

- all `src/` and `spec/` references;
- the eight binary targets in `shard.yml`;
- MCP tool registration and runtime construction;
- the pinned TypeScript source in `vendor/chiasmus`;
- `plans/inventory/typescript_port_inventory.tsv` and `plans/parity.md`;
- newer graph search/indexing implementations already used in production.

No source or spec should be removed merely because it appears in the raw MCP
result. The actionable finding is three obsolete clusters, not 137 independent
dead functions.

## Recommended removals

### R1 — Remove the abandoned `Search::CodeIndex` and its Merkle tree

Confidence: **high**, subject to confirming that this shard no longer promises
these Crystal-only types as a supported public API.

Files:

- `src/chiasmus/search/code_index.cr`
- `src/chiasmus/merkle_tree.cr`
- `spec/chiasmus/search/code_index_spec.cr`
- `spec/chiasmus/merkle_tree_spec.cr`
- the `CodeIndex`-only section in `spec/mcp_server/tools/search_spec.cr`
- `plans/code_index.md` (delete or replace with a short historical note)

Dead-code candidates explained by this cluster include `after_initialize`,
`content_hash_hex`, `same_state?`, `file_diff`, `documents_in_files`,
`with_config`, `from_items`, `root_hash`, and `generate_proof`.

Evidence:

- Production code has no `require` or reference to `CodeIndex`; its consumers
  are specs only.
- `MerkleTree` is referenced only by `CodeIndex`, its own specs, and comments.
- MCP search uses `Search::Engine` with `EmbeddingCache` directly.
- graph/map/search MCP tools now share `Index::ProjectIndex`, which provides the
  resident per-file graph and freshness model that the older `CodeIndex`
  experiment was trying to build separately.
- `CodeIndex` is Crystal-only and is not an upstream export. Upstream's public
  search contract is `VectorStore`, `EmbeddingCache`, `buildSearchCorpus`, and
  `runSearch`; those should not be removed with this cluster.

Why existing specs do not justify keeping it: the specs validate an abandoned
experimental API rather than a runtime contract. They should be removed with
the implementation, not used to preserve it.

Before removal, search the README and release notes for any explicit promise of
`Chiasmus::Search::CodeIndex`. If one exists, record a breaking change or a
deprecation release first.

### R2 — Remove orphaned `Index::FactPersistence`

Confidence: **high**.

Files:

- `src/chiasmus/index/persistence.cr`
- `spec/chiasmus/index/persistence_spec.cr`

Candidates: `to_prolog`, `save_facts`, `merge_facts`, and `facts_to_prolog`.
The unreported companion `load_facts` and `FactEntry` should go with the module.

Evidence:

- No production file requires or references this module.
- Its only consumer is its dedicated spec.
- Current graph facts are generated from `Graph::Facts`, while persistent graph
  extraction is handled by `GraphCache` and the resident state by
  `ProjectIndex`. Keeping a second JSON-to-Prolog fact store creates a competing
  persistence model with no integration point.
- There is no matching upstream public module or inventory obligation.

### R3 — Remove inactive manifest-based adapter auto-discovery

Confidence: **medium-high**. Keep static adapter registration and lookup.

Remove:

- `AdapterRegistry.register_adapter_factory`
- `AdapterRegistry.clear_adapter_factories`
- `AdapterRegistry.discover_adapters` and its private manifest parsing/building
  helpers and factory state
- `Utils::Config::ChiasmusConfig#adapter_discovery` and the `adapterDiscovery`
  JSON field
- manifest-discovery-only sections of
  `spec/chiasmus/graph/adapter_registry_spec.cr`
- adapter-discovery-only sections of `spec/chiasmus/utils/config_spec.cr`
- unused adapter descriptor/factory types if no references remain afterward

Candidates include `register_adapter_factory`, `clear_adapter_factories`,
`discover_adapters`, `default_manifest_paths`, and `adapter_discovery`.

Evidence:

- Runtime code never reads `adapter_discovery` and never calls
  `discover_adapters`; the feature can only be exercised by its specs.
- A manifest cannot load arbitrary Crystal code at runtime. It works only when
  a factory has already been compiled in and registered, but production code
  registers no factories. Consequently the advertised auto-discovery path
  cannot discover a real adapter in a shipped binary.
- Static `register_adapter`, `get_adapter`, extension lookup, and parser
  integration are live and must remain.
- Upstream parity requires the basic adapter registry. The manifest/factory
  mechanism is a Crystal-specific addition, so removing it does not remove an
  upstream API.

If dynamically compiled adapter factories are an intentional future feature,
move this item to a separately owned roadmap and wire at least one production
factory before retaining it. A dormant config flag plus specs is not a usable
feature.

## Smaller candidates requiring an API decision

These have no current production caller but correspond to upstream exports or
plausible shard APIs. Do not remove them solely from this audit.

| Candidate group | Finding | Recommendation |
|---|---|---|
| `GraphCache.evict_lru`, `clear_repo_cache`, `list_snapshots`, `delete_snapshot` | Some are spec-only locally, but cache/snapshot lifecycle functions are upstream exports and support external cache administration. | Keep unless the shard explicitly narrows its public graph API; if narrowed, remove methods and parity rows together. |
| `Search::VectorStore#has?`, `#serialize` | The MCP engine does not need every method, but `VectorStore` is an upstream exported library API with direct parity specs. | Keep. Do not confuse it with the obsolete Crystal-only `CodeIndex`. |
| `EmbeddingCache#put_many`, `#partition_missing` | Upstream methods and useful batching API; engine use may vary. | Keep for parity. |
| `IR::SemanticGraph#symbol_ids`, `#find_symbol`, `Pipeline#refine_async` | Mostly direct/spec consumers, but part of the semantic graph abstraction used by planning and fact generation. `refine_async` also satisfies the repository's non-blocking contract. | Keep until the IR public surface is deliberately redesigned. |
| `ProjectIndex#definitions_named`, `definitions_in_file`, `callers_of`, `callees_of`, `covers?`, `ensure_files_async`, `warm_root_async` | Newly introduced resident-index API. Some convenience queries are not yet production callers, but the graph/map/search integration is active work in the current dirty tree. | Do not prune during this cleanup. Re-audit after the resident-index change lands and its supported query API is documented. |
| `Discovery.discover_file`, `discover_file_async`, registry `for_language` | Used by parity/discovery specs and intended as shard-facing discovery API; the multi-file path is the production bulk implementation. | Keep unless dropping the public single-file discovery API is an explicit breaking change. |
| `CodebaseMap.glob_match` | Upstream exported helper with parity coverage. | Keep even if only tests exercise the direct entry point. |
| `GraphUtil.build_undirected_graph`, call-resolution and suffix-index helpers | Directly tested low-level graph APIs; several are invoked through higher-level graph construction in ways the name-only call graph misses. | Keep unless those low-level exports are deliberately made private. |
| `PrologSolver.normalize_query`, `format_bindings` | Upstream/solver utility surface; solver internals also use related private helpers. | Keep. |

## False positives to retain

### Internal calls missed by extraction

The raw output includes private methods that are visibly called from the same
source module. Examples are CLI `run_tree_sitter_generate`,
`run_tree_sitter_build`, and `redirect_flag`; discovery `pipeline`,
`bundled_dirs`, `scan_max_concurrent`, and `load_grammar_language`; graph
`parse_form`, `next_u`, `import_key`, `export_key`, `default_pipeline`,
`compute_supported_languages`, `parse_runner`, `find_crystal_enclosing_class`,
and tsconfig `rewrite`; review `make_authorization_phase` and
`make_correctness_phase`; solver `ensure_session`, `last_exception`, and
`next_module_name`. These are extraction limitations, not dead code.

`initialize` is especially unusable as a removal candidate: the report merges
many unrelated constructors under one unqualified name.

### Binary, MCP, protocol, and generated callbacks

Keep `build_mcp_transport`, `project_index`, `with_agent_builder`,
`formalization_engine`, `crig_prompt`, `resolve_embedding_model`, `execute_z3`,
`execute_prolog`, `call_typed`, and `repl`. They are reached through binary
targets, MCP tool construction/dispatch, or configured provider paths.

Keep LLM mock `completion`, `stream`, and `completion_request`: these implement
the Crig model protocol and are invoked polymorphically. Keep JSON
`after_initialize` only if R1 is not performed; it is a serialization callback,
not a normal call edge.

### Test-only concurrency seams

The `_for_test` and hook methods are intentionally called from specs to prove
that long operations return before work completes and that cache/index updates
are synchronized. They should stay with the live feature they test. Remove them
only when their owning feature is removed, and remove the corresponding spec in
the same change.

This applies to discovery/extractor hooks, bounded scan overrides, graph cache
write hooks, parallel-I/O read hooks, parser service reset/seed/notify helpers,
analysis/extractor/verify result-boundary hooks, planner report hooks, and
embedding-cache dirty-state hooks.

### Live implementation helpers and public values

Keep parser facade `service`, `service=`, `parse_source_async`, and
`reset_service`; graph `build_class_field_registry`,
`resolve_calls_with_registry`, `has_module_qn?`, `resolve_import`, tree-sitter
node extensions, tsconfig loading, type-environment helpers, and fact
generation; watcher `stop`, `watched_files`, and `scan_changes`; server and
review helpers; search engine/cache/vector-store methods; skills learner/library
methods; and Prolog helpers. Static analysis either loses receiver/type identity
or does not see their external/protocol consumer.

## Execution plan

Perform the cleanup as three independent changes so regressions and parity
ledger updates remain attributable.

1. **Remove R1 (`CodeIndex` + Merkle tree).** Delete implementation, dedicated
   specs, search-tool specs that exercise only `CodeIndex`, and stale planning
   documentation. Confirm `Search::Engine`, MCP search, `VectorStore`, and
   `EmbeddingCache` specs still pass.
2. **Remove R2 (`FactPersistence`).** Delete the orphan module and spec. Confirm
   graph facts, `chiasmus-facts`, graph cache, and `ProjectIndex` tests still
   pass.
3. **Remove R3 (adapter manifest discovery).** Preserve static adapter APIs;
   delete factory/manifest state, dead config, and feature-only specs. Confirm
   built-in and explicitly registered adapters still resolve by language and
   extension.
4. Update affected curated parity rows and plans. Do not mark upstream
   `VectorStore`, `EmbeddingCache`, cache lifecycle, map globbing, or basic
   adapter-registry rows as removed.
5. Run `make format`, `make lint`, and `make test` after each change.
6. Re-run Chiasmus MCP dead-code analysis over `src/**/*.cr`. The raw count
   should fall, but success is defined by removal of the three orphan clusters,
   not by forcing the report to zero.
7. For a higher-signal follow-up, run a second analysis including `spec/**/*.cr`
   and seed the eight `shard.yml` target entry points. Compare both reports and
   retain this source-only report as the conservative baseline.

## Expected outcome

R1 and R2 remove two entire parallel implementations that no production path
loads. R3 removes a configuration promise that cannot work in a compiled
Crystal binary without pre-registered factories. The remaining reported names
are predominantly supported upstream/shard APIs, protocol callbacks, active
internals, or deliberate test seams and should not be mechanically pruned.
