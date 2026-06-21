# Refactoring Plan

Source: chiasmus self-review (2026-06-16), 31 core files, 437 functions, 25 classes, 2658 call edges.

## P1: Break Grammar Management Cycle (HIGH)

**Problem**: 76 functions participate in circular call chains rooted in the grammar management subsystem. The cycle spans `grammar_manager.cr`, `grammar_operations.cr`, `parser_service.cr`, and `cli.cr`.

**Call chain**:
```
ensure_grammar → get_grammar_path → install_grammar
  → install_with_method → install_with_fallbacks
  → make_grammar_available_async → ensure_dependencies_async
  → ensure_grammar_async (loop)
```

**Risk**: Impossible to reason about initialization ordering; potential infinite loop on grammar installation failure; complicates testing.

**Fix**: Introduce explicit lifecycle phases via a state machine:

1. **Phase 1 — Query**: `GrammarRegistry` (read-only) answers "is grammar X available?" without triggering installation. Extract `grammar_available?`, `get_grammar_path`, `grammar_language_for_file` into a pure query module with no side effects.

2. **Phase 2 — Install**: `GrammarInstaller` handles acquisition. Depends on `GrammarRegistry` for metadata but never calls back into the query path. Methods: `install_grammar`, `install_with_method`, `install_with_fallbacks`, `ensure_dependencies_async`.

3. **Phase 3 — Lifecycle**: `GrammarManager` orchestrates the two phases. `ensure_grammar` becomes: query → miss? → install → query again. No recursion.

**Files**:
- `src/chiasmus/graph/grammar_manager.cr` — split into registry + installer + orchestrator
- `src/chiasmus/graph/grammar_operations.cr` — move async install ops to installer
- `src/chiasmus/graph/parser_service.cr` — depend on registry (query) only, not manager

**Verification**: After refactoring, `chiasmus_graph cycles` on these files should return `[]`.

## P2: Reduce Mutex Contention (MEDIUM)

**Problem**: `synchronize` appears at 41 degree in the hub analysis — the 7th most-connected node. Per AGENTS.md, `Channel` is preferred over `Mutex` for concurrent coordination.

**Audit targets** (files with `@@mutex.synchronize`):

| File | Pattern | Candidate for Channel? |
|------|---------|----------------------|
| `grammar_manager.cr` | Guards singleton + grammar cache | Yes — actor/worker fiber pattern (see `solvers/session.cr`) |
| `language_registry.cr` | Double-checked locking for registry init | No — one-shot init, mutex is appropriate |
| `parser_service.cr` | Waiter coalescing for grammar loading | No — already uses Channel for coalescing, mutex guards waiters map |
| `extractor.cr` | `@@merge_mutex` for result aggregation | No — brief critical section during merge |
| `cache.cr` | File manifest access | Maybe — consider lock-free read path with copy-on-write |
| `template_store.cr` | Template persistence | Maybe — consider actor pattern |

**Action**: Convert `grammar_manager.cr` to an actor/worker pattern modeled on `solvers/session.cr`. This eliminates the highest-contention mutex and aligns with the `SolverSession` precedent.

## P3: Prune Dead Code (MEDIUM)

**Problem**: 65 functions unreachable from internal entry points. Most fall into categories:

### Keep (false positives — called from external contexts)
- **Test helpers**: `seed_cache_for_test`, `seed_waiters_for_test`, `notify_for_test`, `set_install_hook_for_test`, `clear_install_hook_for_test`, `reset_for_test` — called from specs
- **Public API**: `parse_async`, `get_language`, `supports_language?`, `supported_languages_async`, `healthcheck`, `run_streamable`, `build_mcp_transport` — called from CLI/server entry points not in analysis scope
- **Grammar async ops**: `git_clone_async`, `git_pull_async`, `npm_install_async`, `tree_sitter_generate_async`, `compile_shared_library_async` — called from grammar_manager internals via dynamic dispatch

### Investigate
- **Registry methods**: `language_for_extension`, `wasm_language?`, `module_export`, `wasm_file`, `extensions_for_language`, `language_for_package`, `unregister_language`, `build_registry` — some may be over-designed API surface from the upstream port. Check if any are actually used; remove unused.
- **Skills subsystem**: `skill_library`, `skill_learner`, `add_learned`, `promote`, `candidates`, `starter_template_names`, `has?` — may indicate incomplete integration. Either wire into MCP tools or mark as stub.

### Remove candidates
- `glob_match` — if unused outside of map.cr (check)
- `next_u` — Mulberry32 PRNG helper, verify it's used
- `require_source_for_add` — CLI validation, verify reachability from CLI entry
- `reinstall_grammar` — verify if exposed via CLI

**Action**: Run `chiasmus_graph dead-code` with ALL source files (including CLI entry points, spec files) to reduce false positives, then remove genuinely dead functions.

## P4: Decompose Graph Analysis Pipeline (LOW)

**Problem**: Community 0 (the graph analysis pipeline) has 110+ members with cohesion 0.05 — the lowest in the codebase. This means functions within the community are loosely related despite being grouped together.

**Action**: Split community 0 into focused modules:
- **Graph building**: `extract_graph`, `merge_*`, `extract_single_file`
- **Graph querying**: `callers`, `callees`, `reachability`, `path_between`, `impact`
- **Graph metrics**: `detect_bridges`, `detect_hubs`, `detect_surprises`, `louvain_phase1`
- **Graph serialization**: `code_graph_to_json`, `graph_to_prolog`, `render_*`

These already live in separate files (`analyses.cr`, `insights.cr`, `facts.cr`, `map.cr`) so the module boundaries exist — the issue is that the call graph doesn't reflect clean separation. Look for cross-cutting calls that could be mediated through the `CodeGraph` data structure instead of direct function calls.

## P5: MCP Timeout Configuration (LOW)

**Problem**: The opencode MCP timeout was 15s, causing all chiasmus graph/map/review tools to time out on real codebases. Fixed to 120s in `~/.config/opencode/opencode.json`.

**Action**: Document recommended timeout in README or installation guide. Consider adding a `--timeout` flag to the MCP server that communicates the expected timeout to clients via MCP capabilities.

---

## Verification Checklist

After each refactoring step, run:

```bash
make format    # crystal tool format --check src spec
make lint      # ameba src spec
make test      # crystal spec
```

Then re-run the chiasmus review to verify improvements:

```bash
# Cycles should decrease after P1
chiasmus_graph analysis=cycles

# Hub degree for synchronize should decrease after P2
chiasmus_graph analysis=hubs

# Dead code count should decrease after P3
chiasmus_graph analysis=dead-code

# Community 0 cohesion should increase after P4
chiasmus_graph analysis=community
```
