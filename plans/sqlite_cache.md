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

## Integrated design

- `GraphCodec` uses `JSON::Serializable` wire DTOs and is shared by SQLite
  entries and named snapshots. The wire schema is isolated from runtime graph
  records and preserves signatures and qualified names.
- `check_file_cache`, `save_file_cache`, `invalidate_file_cache`, and LRU
  eviction now use `SQLiteCacheStore`; no in-memory manifest mirror exists.
- One transaction applies each cache batch. A small crystal-db connection pool
  permits overlapping readers while WAL and the busy timeout coordinate writes.
- Named snapshots remain atomic JSON files because they are immutable named
  artifacts rather than mutable cache rows.
- The migration intentionally starts a fresh `graph-cache.sqlite3` and leaves
  old `manifest.json` caches untouched. No importer is planned unless users
  report that preserving warm caches is worth the extra one-time code.
- Watcher deletion removes the corresponding primary-key row, so superseded or
  deleted graph payloads cannot remain as unreachable blob files.

## Remaining validation

1. Measure cold extraction, warm lookup, watcher bursts, and concurrent MCP
   reads before merging the prototype branch.
2. Add explicit WAL checkpoint policy only if measurements show uncontrolled
   WAL growth during long server sessions.
3. Consider a separate snapshot table only if atomic JSON snapshot management
   becomes a demonstrated bottleneck.

Arrow IPC or Parquet remain export/snapshot formats, not mutable cache stores.
