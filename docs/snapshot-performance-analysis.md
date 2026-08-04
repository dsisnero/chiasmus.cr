# Snapshot Performance Analysis

**Three runs on 161 Crystal files (`lib/crig/src/`)**

**Date**: 2026-07-30

---

## 1. Comparison Table

| Phase | Run 1: Serial, no cache | Run 2: Parallel, no cache | Run 3: Parallel, cache warm |
|-------|:-----------------------:|:-------------------------:|:---------------------------:|
| File I/O (`read_source_files_or_raise`) | 50 ms | 9 ms | **8 ms** |
| Extraction (`extract_graph`) | **4,674 ms** | **2,646 ms** | **649 ms** |
| Cache status | `extracted` | `extracted` | `disk_hit` (161/161) |
| Files re-indexed | 161 | 161 | **0** |
| Analysis (`run_analysis_from_graph`) | 9 ms | 7 ms | **7 ms** |
| Snapshot encode+write | 257 ms | 251 ms | **236 ms** |
| Snapshot JSON size | 4,366,497 bytes | 4,366,497 bytes | 4,366,497 bytes |
| **Total wall time** | **~4,990 ms** | **~2,913 ms** | **~900 ms** |

---

## 2. Per-Run Breakdown

### Run 1: Serial, no cache (baseline)

Environment: baseline (no env vars set)

```
chiasmus.graph.run_analysis.read_files   50.5 ms
chiasmus.graph.extract                 4674.2 ms  ← 94% of total
  ├─ crig.cr (cold start)              2494.8 ms  ← 53% of extraction!
  ├─ completion/message.cr               40.2 ms
  ├─ agent.cr                            42.9 ms
  ├─ 158 other files                   ~2096.3 ms  ← ~13ms avg
chiasmus.graph.run_analysis.analysis      8.8 ms
chiasmus.graph.cache.save_snapshot      257.0 ms
```

**Observation**: The first file (`crig.cr`, 52 lines) takes 2.5s due to tree-sitter Crystal grammar/WASM initialization. After warm-up, files average ~13ms each. Because Crystal extraction is forced serial (`max_concurrent: 1`), files process one-by-one.

### Run 2: Parallel, no cache

Env: `CHIASMUS_CRYSTAL_EXTRACT_CONCURRENT=1`, `CHIASMUS_GRAPH_PARALLEL=1`

```
chiasmus.graph.run_analysis.read_files    8.9 ms
chiasmus.graph.extract                 2646.0 ms  ← 1.8x faster
  ├─ First batch (10 files)       582-688 ms each ← concurrent!
  ├─ completion/message.cr               60.5 ms
  ├─ openai/responses_api.cr             78.5 ms
  ├─ 151 other files              varied (parallel)
chiasmus.graph.run_analysis.analysis      6.8 ms
chiasmus.graph.cache.save_snapshot      251.1 ms
```

**Observation**: Parallel extraction allows the first batch of files (including `crig.cr`) to start concurrently. The cold-start cost is shared across fibers, dropping from 2494ms to ~600ms per file. Overall extraction improves 1.8x.

### Run 3: Cache warm, parallel

Env: same as Run 2, with SQLite cache populated from Run 2

```
chiasmus.graph.run_analysis.read_files    7.6 ms
chiasmus.graph.extract                  648.7 ms  ← 7.2x faster than Run 1
  └─ full cache hit on all 161 files      0 re-indexed
chiasmus.graph.run_analysis.analysis      7.1 ms
chiasmus.graph.cache.save_snapshot      236.4 ms
```

**Observation**: With the cache warm, extraction becomes a pure deserialization from SQLite (no tree-sitter parsing). The 649ms includes checking the cache for all 161 files, decoding 161 cached `CodeGraph`s, merging them, and rewriting path identities.

---

## 3. Per-File Extraction Hotspots (Run 2)

Files with the longest extraction times under parallel execution:

| File | Lines | Defines | Calls | Elapsed | Notes |
|------|-------|---------|-------|---------|-------|
| `openai/responses_api.cr` | 2,183 | 276 | 639 | **78.5 ms** | Largest single file |
| `huggingface/completion.cr` | 790 | 90 | 340 | **35.9 ms** | Dense JSON schema logic |
| `gemini/interactions_api.cr` | 1,915 | 292 | 532 | **71.0 ms** | Large + complex |
| `gemini/completion.cr` | 1,699 | 229 | 441 | **58.5 ms** | |
| `openrouter/completion.cr` | 1,459 | 189 | 510 | **67.5 ms** | |
| `openai/completion.cr` | 1,538 | 213 | 487 | **61.2 ms** | |
| `anthropic/completion.cr` | 1,495 | 199 | 525 | **69.5 ms** | |
| `ollama.cr` | 960 | 117 | 360 | **50.9 ms** | |
| `deepseek.cr` | 836 | 116 | 347 | **46.7 ms** | |
| `completion/message.cr` | 1,325 | 256 | 385 | **60.5 ms** | |

The 10 slowest files account for ~65% of total extraction time.

---

## 4. Snapshot Serialization

The `save_snapshot` phase is consistent across all runs (~250ms):

```
encode (CodeGraph → JSON):   ~250 ms
write + rename (tmp+atomic):   ~2 ms
total:                        ~252 ms
```

JSON size: 4,366,497 bytes (4.2 MB) for 7,326 defines + 14,864 calls + 240 imports.

The encode step is the bottleneck here — serializing a large `CodeGraph` struct tree to JSON via `GraphCodec.encode`. This is CPU-bound and scales linearly with graph size.

---

## 5. Recommendations

### Env vars to enable (immediate)
```
CHIASMUS_GRAPH_PARALLEL=1               # parallel CPU extraction
CHIASMUS_CACHE_DIR=<path>               # enable per-file cache
```

Crystal extraction now honors its requested bounded concurrency by default;
`CHIASMUS_CRYSTAL_EXTRACT_CONCURRENT` is no longer required.

### Completed
1. **Default to bounded-concurrent Crystal extraction** — `extract_graph` no longer forces Crystal-only projects to one worker. The requested bound now applies uniformly; `CHIASMUS_GRAPH_PARALLEL=1` remains the explicit CPU-worker opt-in.

2. **Pre-warm the Crystal grammar** — default extraction resolves the Crystal language once before it starts file workers. The parser service's synchronized language cache is then reused by every worker, removing grammar initialization from the first file's extraction path.

3. **Isolate snapshot persistence** — snapshot writes have a dedicated worker and `chiasmus_graph` waits only for its named snapshot. Unrelated per-file cache writes can no longer add queue latency before the snapshot becomes observable.

### Code changes to consider
1. **Handwritten JSON encode** — the snapshot encode remains CPU-bound. A direct-to-file `Document#to_json(io)` experiment was discarded: it measured 506–531ms versus the prior 181–261ms on the 4.2MB fixture. Any future encoder change should be benchmarked against the current string-backed implementation and preserve the exact wire format.

2. **Selective extraction** — for tools like `chiasmus_map` or `chiasmus_graph` that only need summary/facts, skip snapshot save if no `save_snapshot` param is given (already the case).

### Expected latency with all improvements
```
Cold extraction (161 files):   ~2,600 ms  (parallel, no cache)
Warm extraction (161 files):     ~650 ms  (parallel, full cache hit)
Snapshot encode + write:         ~250 ms  (constant per snapshot)
```
