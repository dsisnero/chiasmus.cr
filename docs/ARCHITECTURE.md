# Architecture

## Overview

Chiasmus.cr is an MCP server for formal verification with Z3 SMT solver, SWI-Prolog,
and tree-sitter-based source code analysis. It exposes 12 tools to LLM clients via
JSON-RPC over stdio.

```
opencode / MCP client
  │
  ▼  stdio JSON-RPC
┌──────────────────────────────────────────────────┐
│  MCP::Server::Server                             │
│    ├─ ToolDispatcher (bounded semaphore)          │
│    ├─ verify / formalize / solve / learn          │
│    ├─ graph / map / search / craft / review       │
│    └─ lint / skills / crig                        │
├──────────────────────────────────────────────────┤
│  Graph::Analyses         Formalize::Engine        │
│    ├─ Extractor            ├─ Solver factory      │
│    │   ├─ BoundedWork      │   ├─ Z3              │
│    │   ├─ Parser::Service  │   └─ SWI-Prolog      │
│    │   └─ Sync::Map cache  └─ Correction loop     │
│    ├─ GraphCache                                  │
│    └─ Graph algorithms    Skills::Library          │
├──────────────────────────────────────────────────┤
│  Shards: tree_sitter, z3, crolog, crig, sync-map │
│  Cache:  ~/.cache/chiasmus/                       │
└──────────────────────────────────────────────────┘
```

## Concurrency is the central design concern

The server handles multiple LLM clients; extraction, search, and analysis can run in
overlapping fibers. Every long-running path uses non-blocking patterns.

### 1. ToolDispatcher — bounded semaphore

Limits concurrent tool invocations to `System.cpu_count`. Prevents unbounded fiber
spawn from saturating the CPU when an LLM fires many tools in rapid succession.

```
┌────────────┐  acquire slot  ┌──────────────┐
│  incoming  │───────────────▶│  @slots       │──▶ invoke → response
│  request   │                │  (Channel)    │
└────────────┘                └──────────────┘
    capacity = CPU count
```

Source: `src/chiasmus/mcp_server/server.cr:27-51`

### 2. BoundedWork — parallel file extraction

Extracts call graphs from N files concurrently with a configurable worker pool.
Two execution modes, chosen at compile time:

| Mode | Mechanism | When |
|------|-----------|------|
| Fibers (default) | `spawn { }` | Standard `-Dchiasmus_cli` |
| True threads | `Fiber::ExecutionContext::Parallel` | `-Dpreview_mt -Dexecution_context` |

The thread mode requires the MT runtime. With `-Dexecution_context`, parallel is
on by default (opt-out via `CHIASMUS_GRAPH_PARALLEL=0`).

```
┌─────┐  ┌─────┐  ┌─────┐
│file1│  │file2│  │file3│ ...
└──┬──┘  └──┬──┘  └──┬──┘
   │ spawn  │ spawn  │ spawn
   ▼        ▼        ▼
┌─────┐  ┌─────┐  ┌─────┐
│ w1  │  │ w2  │  │ w3  │  ← bounded by max_concurrent slots
└──┬──┘  └──┬──┘  └──┬──┘
   │        │        │
   ▼        ▼        ▼
  ordered results array (preserves input index)
```

Source: `src/chiasmus/utils/bounded_work.cr`

### 3. Sync::Map — lock-free grammar cache

Loaded `TreeSitter::Language` objects are cached in a concurrent map. Multiple
fibers can read/write without external locking, avoiding contention on the
hot path (every file parse checks the cache).

```crystal
# Before: Hash + Mutex (serialized access)
@state_mutex.synchronize { @grammar_cache[lang]? }

# After: Sync::Map (concurrent access, no lock contention)
@grammar_cache[lang]?
```

Source: `src/chiasmus/graph/parser_service.cr:155` (uses `DSisnero/sync-map`)

### 4. Waiter coalescing — dedup concurrent requests

When multiple fibers request the same grammar or language simultaneously, only one
initiates the download/build/load. The others attach to a `pending_requests` list
and are notified when the leader completes.

```
fiber A ──▶ pending_requests["python"] = [chA] ──▶ spawn resolve("python")
fiber B ──▶ pending_requests["python"] << chB      │
fiber C ──▶ pending_requests["python"] << chC      │
                                                    ▼
                                            load grammar → notify all
```

Used in: `GrammarManager.ensure_grammar_async`, `Parser::Service.get_language_async`

### 5. Channel-based async — caller controls blocking

All long-running operations return `Channel(T)`. The caller decides whether to
block, pipeline, or select with timeout:

```crystal
# Block
result = extract_graph_async(files).receive

# Pipeline
ch1 = extract_graph_async(files1)
ch2 = extract_graph_async(files2)
combined = merge(ch1.receive, ch2.receive)

# Timeout
select
when result = ch.receive
  process(result)
when timeout(60.seconds)
  raise "extraction timed out"
end
```

Pattern used in: `Extractor`, `Analyses`, `GrammarManager`, `Parser::Service`

### 6. GraphCache — extraction result cache

Two-tier persistent cache keyed by SHA-256 of `content + "\0" + abs_path`:

```
~/.cache/chiasmus/<repo_sha256>/
  manifest.json        ← hash → path mapping, sorted by mtime
  files/
    <sha256>.json      ← serialized CodeGraph per file
  snapshots/
    <name>.json        ← named full-graph snapshots (diff baseline)
```

- **Async writes**: `save_file_cache_async` enqueues via bounded channel (capacity 32),
  processed by a single background fiber. Non-blocking for the extraction hot path.
- **LRU eviction**: when total repo size exceeds `DEFAULT_MAX_BYTES` (64 MB), oldest
  entries by mtime are evicted.
- **Schema versioning**: `SCHEMA_VERSION = "3"` auto-upgrades and invalidates old caches.
- **Flush on shutdown**: `GraphCache.flush_async_writes` is called in `on_close` to
  drain the async write queue before process exit.

Source: `src/chiasmus/graph/cache.cr`

### 7. Grammar cache — two-tier

| Tier | Location | Lifetime |
|------|----------|----------|
| Disk (compiled `.dylib`/`.so`) | `~/.cache/chiasmus/grammars/<lang>/` | Persists across restarts |
| Memory (`Sync::Map`) | `Parser::Service.@grammar_cache` | Process lifetime |

16 languages pre-compiled and cached. Grammar re-compilation only happens on version
updates. Cold start (first process) pays the cost once; warm starts hit disk cache.

### 8. MCP request lifecycle — graceful shutdown

The transport tracks inflight requests so shutdown waits for completion:

```
begin_request      inflight++   ← request arrives
  spawn do
    handler.call                ← tool dispatch + invoke
    end_request     inflight--  ← response sent
  end

close
  drain_requests    ← blocks until inflight == 0
  flush_async_writes ← persist pending cache writes
  @_on_close.call   ← cleanup (close grammars, etc.)
```

Source: `src/chiasmus/mcp_server/server.cr:216-228`

## Throughput path: chiasmus_graph

The fastest path through the system for a graph analysis request:

```
1. MCP request arrives
2. register_tools lambda fires
3. ToolDispatcher acquires semaphore slot
4. GraphTool.invoke → Analyses.run_analysis_async.receive
   │
5. GraphCache.check_file_cache   ← SHA-256 hash; separates hits/misses
   │
6. BoundedWork.map_ordered       ← parallel extraction of misses only
   │  ├─ Parser.parse            ← tree-sitter parse
   │  │   └─ Sync::Map cache hit ← instant if language already loaded
   │  ├─ AdapterRegistry.get     ← language walker
   │  └─ merge_graph_under_lock  ← Mutex-guarded merge
   │
7. run_analysis_from_graph       ← O(V+E) native algorithm
8. GraphCache.save_file_cache    ← async, non-blocking
9. Result → JSON → MCP response
```

**With warm file cache:** steps 5-8 complete in ~0ms (all files are cache hits).
**With warm grammar cache:** step 6 per-file parse is ~100-500ms (tree-sitter + walker).
**Cold everything:** step 6 per-file is ~5-20s (grammar compile/load dominates).

The `warm_cache.cr` script populates the extraction cache in one request, letting
`BoundedWork.map_ordered` parallelize internally. Subsequent `chiasmus_graph` calls
are all cache hits.

## Compile-time flags

| Flag | Effect |
|------|--------|
| `-Dchiasmus_cli` | Enables CLI entry point (required for binary, excluded for tests) |
| `-Dpreview_mt -Dexecution_context` | Enables true thread-parallel extraction via `Fiber::ExecutionContext::Parallel` |

Build with threads:
```bash
make build_release    # release + MT + parallel extraction by default
```

## Key invariants

1. **No shared mutable state without synchronization.** Prefer `Mutex` for guarded
   access, `Atomic` for counters, `Channel` for communication, `Sync::Map` for
   concurrent key-value stores.
2. **Long-running operations return `Channel(T)`** — never block the calling fiber.
3. **Non-thread-safe resources get actor/worker fibers** — see Prolog session
   (`solvers/session.cr`) and grammar loading (`parser_service.cr` waiter coalescing).
4. **The extraction cache is the primary throughput multiplier.** ~800x speedup
   on repeated requests for unchanged files.
