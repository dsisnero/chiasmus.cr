# Chiasmus Snapshot Code Flow

**Source**: `src/` — chiasmus codebase itself, traced via `chiasmus_graph` + `chiasmus_map`

**Generated**: 2026-07-30

---

## 1. Overview

The snapshot system persists a `CodeGraph` (extracted call graph) to a named JSON file on disk so it can be loaded later for diff/regression analysis. There are two snapshot mechanisms:

| Mechanism | Scope | Storage | Concurrency |
|-----------|-------|---------|-------------|
| **Persistent snapshots** (`GraphCache`) | Cross-session, named, on disk | `{cache_dir}/{repo_key}/snapshots/{name}.json` | Async writer fiber (non-blocking) |
| **In-memory snapshots** (`ProjectIndex`) | Per-process, generation-numbered, in actor | `ProjectIndexSnapshot` record | Actor fiber (serialized via Channel) |

---

## 2. Entry Points

There are **four** entry points into the snapshot system:

### 2a. MCP Tool (`chiasmus_graph`)

File: `src/chiasmus/mcp_server/tools/graph.cr`

```
MCP request (save_snapshot="crig")
  └─ GraphTool#invoke()                          :16
      └─ Types::GraphInput.from_json()            :17  → reads save_snapshot field
      └─ Graph::AnalysisRequest.new()             :29
      └─ run_indexed_analysis()                   :42
          ├─ run_extracted_analysis()              :76  ← (if save_snapshot || no index)
          │   └─ Analyses.run_analysis_async()     :139
          │       └─ .receive()                    :139
          │   └─ GraphCache.flush_async_writes()   :151  ← blocks until saved
          └─ run_and_index_analysis()              :98  ← (if indexed, no snapshot save)
```

Key decision at `:75-76`:
```crystal
return run_extracted_analysis(files, request, cache_dir, repo_key, max_bytes, save_snapshot) unless index
return run_extracted_analysis(files, request, cache_dir, repo_key, max_bytes, save_snapshot) if save_snapshot
```

If `save_snapshot` is set, the tool always takes the **extracted** (non-indexed) path — the fresh graph is saved as a snapshot.

### 2b. CLI (`chiasmus-facts`)

File: `src/chiasmus/facts_cli.cr`

```
CLI args (--dir . --language crystal)
  └─ FactsCLI#run()                                    :34
      └─ Extractor.extract_graph()                      :92  → build CodeGraph
      └─ FactsSnapshot.snapshot_name()                   :103 → deterministic name from (lang, dir, entry_points, insights)
      └─ GraphCache.save_snapshot_async()                :104 → fire-and-forget
      └─ Metadata.new(cache_dir, repo_key, snapshot)     :105 → embed metadata
      └─ Analyses.run_analysis_from_graph()              :113 → emit Prolog facts
      └─ GraphCache.flush_async_writes()                 :117 → flush before exit
```

### 2c. Diff (internal — loaded via `against`)

File: `src/chiasmus/graph/analyses.cr`

```
AnalysisRequest(analysis: Diff, against: "baseline")
  └─ Analyses#handle_diff()                           :310
      └─ GraphCache.load_snapshot(against_name, ...)   :314
      └─ GraphDiffer.diff(before, graph)               :317
```

### 2d. Plan/Parity tools (facts-linked)

File: `src/chiasmus/graph/facts_snapshot.cr`

```
FactsSnapshot.load_graph_from_facts(path)             :57
  └─ parse_metadata_line?(line)                       :44  → parse "% graph_snapshot {json}"
  └─ GraphCache.load_snapshot(metadata.snapshot, ...)  :65
```

---

## 3. Core Snapshot Functions

### 3a. `GraphCache.save_snapshot` — synchronous write

File: `src/chiasmus/graph/cache.cr:196`

Callers: `process_async_writes`, `invoke` (test hook)
Callees: `validate_snapshot_name`, `resolve_cache_paths`, `GraphCodec.encode`, `unique_tmp_path`, atomic `File.rename`

```
save_snapshot(name, graph, cache_dir, repo_key?)
  ├─ validate_snapshot_name(name)                     :197
  │   └─ rejects empty, '/', '\\', '\0'               :335-336
  ├─ before_snapshot_write_hook.try(&.call)           :199  ← test hook
  └─ @@mutex.synchronize                              :200
      ├─ resolve_cache_paths(cache_dir, repo_key)     :201
      │   └─ returns { repo_dir, ... }
      ├─ snap_dir = <repo_dir>/snapshots/             :202
      ├─ Dir.mkdir_p(snap_dir)                       :203
      ├─ target = snap_dir/{name}.json                :205
      ├─ tmp = unique_tmp_path(target)                :206  → "{target}.tmp.{random}"
      ├─ File.write(tmp, GraphCodec.encode(graph))    :207  → serialize + write temp
      └─ File.rename(tmp, target)                     :208  → atomic replace
```

**Atomic write guarantee**: Writes to a temp file first, then atomically renames. This prevents partial snapshots from being read.

### 3b. `GraphCache.save_snapshot_async` — non-blocking

File: `src/chiasmus/graph/cache.cr:212`

Callers: `run_analysis`, `run` (FactsCLI)

```
save_snapshot_async(name, graph, cache_dir, repo_key?)
  ├─ validate_snapshot_name(name)
  └─ async_write_channel.send(SnapshotWriteRequest)  :214
      └─ channel has buffer of 32
      └─ received by singleton writer fiber
```

### 3c. Async Writer Fiber

File: `src/chiasmus/graph/cache.cr:294-324`

```
async_write_channel()                                 :294
  └─ lazily creates Channel(AsyncWriteRequest).new(32)
  └─ spawn { process_async_writes(channel) }          :300
      ├─ loop: receive? → case request
      │   ├─ FileCacheWriteRequest → save_file_cache()
      │   ├─ SnapshotWriteRequest  → save_snapshot()   :314
      │   └─ FlushRequest         → ack.send(true)     :316
      └─ errors are caught → stderr, fiber continues
```

**Concurrency design**: A single background fiber serializes all async writes (file cache + snapshots). This avoids SQLite WAL contention and prevents concurrent snapshot writes from racing. The fiber is created lazily on first use.

### 3d. `GraphCache.load_snapshot` — read back

File: `src/chiasmus/graph/cache.cr:223`

Callers: `handle_diff`, `load_graph_from_facts`

```
load_snapshot(name, cache_dir, repo_key?)
  ├─ resolve_cache_paths(cache_dir, repo_key)
  ├─ target = <repo_dir>/snapshots/{name}.json        :225
  ├─ return nil unless File.exists?(target)            :226
  └─ GraphCodec.decode(File.read(target))              :227
      └─ JSON → Document → CodeGraph (via to_domain)
```

### 3e. Supporting: `GraphCodec.encode` / `GraphCodec.decode`

File: `src/chiasmus/graph/graph_codec.cr`

```
encode(graph : CodeGraph) → String                    :167
  └─ from_domain(graph).to_json                       :168
      └─ Domain types (Definition, Call, Import, etc.) → JSON Document

decode(raw : String) → CodeGraph                      :171
  └─ to_domain(Document.from_json(raw))               :172
      └─ JSON Document → domain types → DefinesFact, CallsFact, etc.
```

The codec converts between the internal `CodeGraph` (with Crystal-specific types like `SymbolKind`, `Span`) and a JSON-friendly `Document` struct. This is the **serialization format** used both for on-disk cache entries and named snapshots.

---

## 4. Snapshot Lifecycle

### MCP Tool Flow (`chiasmus_graph`)

```
                 ┌─────────────────────────┐
                 │  MCP Client             │
                 │  save_snapshot: "crig"  │
                 └─────────┬───────────────┘
                           │
                 ┌─────────▼───────────────┐
                 │  GraphTool#invoke()     │
                 │  src/mcp_server/        │
                 │  tools/graph.cr         │
                 └─────────┬───────────────┘
                           │
                           ▼
              ┌────────────────────────┐
              │ run_extracted_analysis │
              │ (always used when      │
              │  save_snapshot set)    │
              └─────────┬──────────────┘
                        │
▼───◆───◆───◆───◆───◆───◆───◆───◆───◆───◆───◆───▼
│ Analyses.run_analysis()                    │
│ src/graph/analyses.cr                     │
│                                           │
│  1. read_source_files_or_raise(files)     │  ← read source
│  2. Extractor.extract_graph(files, ...)   │  ← tree-sitter parse
│  3. save_snapshot_async(name, graph, ...) │  ← async persist (fire & forget)
│  4. run_analysis_from_graph(graph, req)   │  ← analysis on the graph
└─────────────────┬─────────────────────────┘
                  │
        ┌─────────▼──────────┐
        │  GraphCache         │
        │  async writer fiber │
        │                     │
        │  save_snapshot():   │
        │  ├─ validate name   │
        │  ├─ mutex lock      │
        │  ├─ snap_dir/       │
        │  ├─ {name}.json     │
        │  ├─ tmp+rename      │
        │  └─ atomic!         │
        └─────────────────────┘
                  │
        ┌─────────▼──────────┐
        │  MCP boundary      │
        │  flush_async_writes│  ← wait for writer ack
        │  (.receive)        │
        └─────────────────────┘
                  │
                  ▼
        RETURN result (analysis payload)
```

### Facts CLI Flow (`chiasmus-facts`)

```
FactsCLI#run()
│
├── 1. scan_files(language, dir)           → file list
├── 2. read_source_files_or_raise(files)   → {path, content} pairs
├── 3. Extractor.extract_graph(...)        → merge per-file graphs
│
├── 4. FactsSnapshot.snapshot_name(...)    → "facts-{sha256[0:24]}"
│      Deterministic: SHA-256(lang + dir + entry_points + insights)
│
├── 5. GraphCache.save_snapshot_async(...) → async persist
│      (fire-and-forget to writer fiber)
│
├── 6. Metadata.new(...)                   → {cache_dir, repo_key, snapshot_name}
│
├── 7. Analyses.run_analysis_from_graph    → emit Prolog facts
│
├── 8. output metadata_line               → "% graph_snapshot {\"cache_dir\"..., \"snapshot\":\"facts-...\"}"
│      (embedded as comment in facts output)
│
└── 9. flush_async_writes                  → ensure durable before exit
```

The metadata line embedded in the facts output creates a **self-referencing link** — the facts file knows where its source snapshot lives, enabling later reload via `FactsSnapshot.load_graph_from_facts`.

---

## 5. In-Memory Snapshot: `ProjectIndex`

File: `src/chiasmus/index/project_index.cr`

The `ProjectIndex` actor maintains its own **in-memory snapshot** concept for fast indexed lookups:

```
record ProjectIndexSnapshot,
  generation : Int64,                              ← incrementing version
  graph : CodeGraph,                               ← merged graph
  definitions_by_name,                             ← O(1) name lookups
  definitions_by_file,                             ← O(1) file lookups
  callers_by_callee,                               ← O(1) caller queries
  callees_by_caller,                               ← O(1) callee queries
  imports_by_file,
  exports_by_file,
  files_by_path,
  graphs_by_file,                                  ← per-file graphs
  fingerprints                                     ← file size + mtime for staleness
```

Key differences from persistent snapshots:

| Aspect | Persistent (`GraphCache`) | In-Memory (`ProjectIndex`) |
|--------|--------------------------|----------------------------|
| Storage | JSON file on disk | Crystal record in heap |
| Naming | User-supplied string | Generation number (auto-increment) |
| Write | Async fiber + mutex | Synchronous actor message |
| Read | File I/O + JSON parse | Direct field access |
| Refresh | Manual snapshot | Auto on every file upsert/remove |
| Use case | Diff across branches/sessions | Fast indexed lookups in same session |

The `ProjectIndex#build_snapshot` method (line 296) materializes all index structures from per-file `CodeGraph`s, sorted by path. Every `UpsertRequest`, `UpsertManyRequest`, `RemoveRequest`, or `ApplyBatchRequest` increments the generation and rebuilds.

---

## 6. Diff: Consuming Snapshots

File: `src/chiasmus/graph/diff.cr`

```
GraphDiffer.diff(before : CodeGraph, after : CodeGraph) → GraphDiffResult
  ├─ collect_nodes(before/after)             → node sets
  ├─ added = after - before                  → new symbols
  ├─ removed = before - after                → deleted symbols
  ├─ collect_edge_keys(before/after)         → "src\0tgt" keys
  ├─ added_edges = after - before            → new call edges
  ├─ removed_edges = before - after          → deleted call edges
  ├─ diff_by_key(imports)                    → added/removed imports
  └─ diff_by_key(exports)                    → added/removed exports
```

The `handle_diff` function in `analyses.cr` (:310-329) orchestrates:
1. Checks `against` and `snapshot_cache_dir` are provided
2. `GraphCache.load_snapshot(against_name, ...)` — loads the baseline
3. Returns error if snapshot not found
4. `GraphDiffer.diff(before, graph)` — computes the delta
5. Returns structured JSON with added/removed nodes, edges, imports, exports + summary text

---

## 7. Guard: Snapshot Name Collision

File: `src/chiasmus/graph/analyses.cr:155`

```crystal
if save_snapshot && request.analysis.diff? && request.against == save_snapshot
  return error("save_snapshot and against cannot name the same snapshot")
end
```

Prevents a `save_snapshot` + `against` with the same name, which would overwrite the baseline before the diff runs.

---

## 8. Wire Format

Snapshots are JSON files with the `GraphCodec::Document` schema:

```json
{
  "defines": [
    {"file": "...", "name": "...", "kind": "function", "span": {...}, "signature": "...", "qualified_name": "..."}
  ],
  "calls": [
    {"caller": "...", "callee": "...", "callee_qn": "...", "caller_qn": "..."}
  ],
  "imports": [
    {"file": "...", "name": "...", "source": "..."}
  ],
  "exports": [
    {"file": "...", "name": "..."}
  ],
  "contains": [
    {"parent": "...", "child": "..."}
  ],
  "files": [
    {"path": "...", "language": "...", "line_count": ..., "token_estimate": ..., "file_doc": "..."}
  ],
  "_typeInfo": [
    {"file": "...", "class_fields": [...], "class_methods": [...], "class_extends": [...], "pending_calls": [...]}
  ]
}
```

Name validation: no empty names, no path separators (`/`, `\`), no null bytes.

---

## 9. Key Files Summary

| File | Role |
|------|------|
| `src/chiasmus/graph/cache.cr` | `GraphCache` — save_snapshot, save_snapshot_async, load_snapshot, async writer fiber, list/delete |
| `src/chiasmus/graph/analyses.cr` | `Analyses` — run_analysis with save_snapshot param, handle_diff for loading + diffing |
| `src/chiasmus/graph/facts_snapshot.cr` | `FactsSnapshot` — metadata embedding in Prolog output, deterministic name derivation |
| `src/chiasmus/graph/graph_codec.cr` | `GraphCodec` — CodeGraph ↔ JSON serialization |
| `src/chiasmus/graph/diff.cr` | `GraphDiffer` — set-difference on two CodeGraphs |
| `src/chiasmus/mcp_server/tools/graph.cr` | `GraphTool` — MCP tool entry, routes save_snapshot param |
| `src/chiasmus/mcp_server/types.cr` | `GraphInput` — input struct with `save_snapshot : String?` |
| `src/chiasmus/facts_cli.cr` | `FactsCLI` — CLI entry, auto-saves snapshot + embeds metadata in facts output |
| `src/chiasmus/index/project_index.cr` | `ProjectIndex` — in-memory actor with generation-numbered snapshots |

---

## 10. Call Graph (from chiasmus_graph)

```
save_snapshot_async
  callers: run, run_analysis
  └─→ async_write_channel.send(SnapshotWriteRequest)
      └─→ process_async_writes (fiber)
          └─→ save_snapshot
              ├─ validate_snapshot_name
              ├─ resolve_cache_paths
              ├─ GraphCodec.encode
              └─ atomic File.rename

save_snapshot
  callers: process_async_writes, invoke(test)
  callees: validate_snapshot_name, resolve_cache_paths, encode, unique_tmp_path, mkdir_p

load_snapshot
  callers: handle_diff (diff analysis), load_graph_from_facts (facts replay)
  callees: resolve_cache_paths, GraphCodec.decode

run_analysis (with save_snapshot param)
  callees: read_source_files_or_raise, extract_graph, save_snapshot_async, run_analysis_from_graph
```
