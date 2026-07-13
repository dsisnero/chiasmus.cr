# SQLite graph cache and batched watcher

## Prototype status

- `SQLiteCacheStore` owns a SQLite database using WAL, normal synchronous mode,
  and a five-second busy timeout.
- `cache_entries.path` is the primary key. A single transaction applies a
  batch of replacements/additions and deletions without an in-memory manifest.
- Reopening the database restores entries directly from SQLite.
- `Watcher` now publishes one `ChangeSet(added, modified, deleted)` per scan.
- The MCP server parses the changed paths with bounded concurrency, invalidates
  deleted cache paths in one call, and applies all resident index changes in one
  actor generation.

## Worktree setup finding

Recursive submodule initialization and `wt step copy-ignored` cloned or copied
roughly 290 MiB before cache work could start. The project Worktrunk hooks now:

- share immutable `lib` shard checkouts from the primary worktree;
- keep build outputs and `.crystal-cache` worktree-local;
- synchronize submodule URLs without initializing every submodule;
- leave vendor and grammar source checkout initialization to tasks that need
  those specific sources.

Runtime grammar libraries should be supplied through XDG or
`CHIASMUS_GRAMMAR_DIR`; a grammar source submodule is not a runtime dependency.

## Migration still required

The prototype deliberately does not route the existing `GraphCache` public API
through SQLite yet. Before changing the default backend:

1. Move `CodeGraph` serialization behind a backend-neutral codec.
2. Adapt `check_file_cache`, `save_file_cache`, and
   `invalidate_file_cache` to `SQLiteCacheStore` batch calls.
3. Keep named snapshots separate initially; migrate them only after per-file
   cache parity is proven.
4. Add a one-time `manifest.json` importer or deliberately start with a fresh
   `graph-cache.sqlite3` and leave the old cache untouched.
5. Add byte-budget eviction ordered by `accessed_at_ms` and WAL checkpointing.
6. Measure cold extraction, warm lookup, watcher bursts, and concurrent MCP
   reads before making SQLite the default.

Arrow IPC or Parquet remain export/snapshot formats, not mutable cache stores.
