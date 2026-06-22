# Concurrency Plan

Date: 2026-06-21

## Goal

Move the repo toward consistent Go/Crystal-style concurrency:

- long-running work should start asynchronously and avoid blocking the caller
- concurrency should be bounded by default
- shared mutable state should be isolated or synchronized
- I/O stages and CPU stages should be composed intentionally instead of each subsystem inventing its own pool

This plan is based on:

- the repo's current concurrency code
- the `crystal-concurrency` skill patterns
- the current hot spots in `graph`, `discovery`, `mcp_server`, `parity`, and `utils`

## Decision

We do **not** want a "parallel reader" as the primary abstraction.

We want a **generic bounded worker abstraction over an enumerable of items**, with file reading as one caller of that abstraction.

Reason:

- file reading is only one case of the same concurrency shape
- the repo already repeats the same pattern for file reads, graph extraction, discovery, and parity mapping
- a reader-only abstraction pushes us toward more one-off helpers instead of one reusable primitive
- several call paths want more than "read all files"; they want `path -> validate -> read -> parse -> extract -> cache/save`

So the direction should be:

1. build a small, reusable bounded work primitive
2. use it first for file-path work
3. add explicit pipelines only where staged overlap and backpressure are real wins

## Crystal Concurrency Patterns We Should Use

### 1. Bounded worker pool

Use for:

- file-path processing
- graph extraction over many files
- search corpus preparation
- parity inventory fan-out

Recommended shape:

- input: `Enumerable(T)` or `Array(T)`
- concurrency bound: `max_concurrent`
- output mode:
  - ordered collect
  - unordered stream
  - collect-or-raise

Implementation guidance:

- use `Channel(Bool)` for semaphore/signaling, not `Channel(Nil)`
- workers must always publish one terminal result per input
- collectors must drain all results before raising

### 2. Actor / ownership fiber

Use for:

- non-thread-safe resources
- shared mutable caches with serialized mutation
- setup/install lifecycle coordination

Already good models:

- `src/chiasmus/solvers/session.cr`
- `src/chiasmus/graph/parser_service.cr`
- `src/chiasmus/graph/grammar_manager.cr`

### 3. Pipeline with bounded channels

Use only when stages have distinct resource profiles and overlap is valuable.

Good candidates:

- `path -> stat/filter -> read -> parse/extract -> persist`
- `files -> extract graph -> build corpus -> embed/query`

Do **not** build a generic DAG framework yet. Start with 2-4 stage linear pipelines for the hot paths.

### 4. `ExecutionContext` only for proven CPU hot spots

Use only behind `-Dpreview_mt -Dexecution_context`, and only after the current shared-state cleanup is complete.

Good candidates later:

- graph insight calculations in `src/chiasmus/graph/insights.cr`
- independent graph analyses in `src/chiasmus/graph/facts.cr`
- possibly parts of graph extraction if parse/walk work proves CPU-dominant

Not a first move:

- grammar install flows
- file I/O
- MCP request dispatch

### 5. Cancellation, timeout, and close-safe channel use

Rules to standardize:

- signal channels use `Channel(Bool)`
- `select` on closeable channels should use `receive?`
- `done.close` is the broadcast cancellation pattern
- timeout helpers should return close-safe channels and avoid `Channel(Nil)` ambiguity

## Current Repo Hot Spots

### A. `src/chiasmus/graph/parallel_io.cr`

Current issues:

- unbounded `spawn` per file
- abstraction is too narrow: file-read specific instead of generic work
- two variants (`parallel` and `or_raise`) duplicate the same worker shape
- no reusable result envelope for other path-based tasks

Impact:

- scales poorly on large file sets
- encourages copy/paste concurrency elsewhere
- blocks reuse by `search`, `map`, `graph`, and future staged extraction

Conclusion:

- replace this with a generic bounded work primitive
- keep file-reading wrappers as thin adapters on top

### B. `src/chiasmus/mcp_server/tools/search.cr`

Current issues:

- `read_search_files` is fully sequential: `File.info` + `File.read`
- the whole path is monolithic:
  - filter/read
  - build `SourceFile`
  - `Extractor.extract_graph`
  - build corpus
  - embedding search
- warnings are accumulated inline rather than as worker results

Impact:

- this is one of the clearest end-user latency paths
- it performs both file I/O and expensive downstream work on the request path

Conclusion:

- first move: convert file preparation to the generic bounded path worker
- second move: consider a staged search pipeline if measurements show file prep and extraction overlap materially

### C. `src/chiasmus/graph/extractor.cr`

Current issues:

- already bounded, but with `Channel(Nil)` semaphore
- the concurrency is embedded directly in the extractor instead of using a shared primitive
- cache persistence is fire-and-forget
- merge uses a mutexed global accumulator, so work is parallel only in the file-local extraction stage

What is good:

- per-file extraction is already isolated and naturally parallelizable
- merge is brief and correctness-oriented

Conclusion:

- do not rewrite this as a pipeline first
- first refactor it onto the shared bounded work primitive
- then measure whether a staged `extract -> merge -> persist` pipeline buys anything over the simpler pool

### D. `src/chiasmus/discovery/pipeline.cr`

Current issues:

- good bounded shape, but it is another local implementation of the same pool
- still uses `Channel(Nil)` semaphore
- timeout handling is bespoke
- scan phase is still sequential file walking + reading

Conclusion:

- this file is the strongest proof that the repo already wants a shared bounded worker primitive
- after the primitive exists, this should become a thin orchestration layer

### E. `src/chiasmus/parity.cr`

Current issues:

- `parallel_map` duplicates the worker-pool shape
- uses `Channel(Nil)` semaphore
- lives outside a shared concurrency utility

Conclusion:

- migrate to the shared primitive instead of maintaining a parallel one-off map implementation

### F. `src/chiasmus/utils/timeout.cr`

Current issues:

- still uses `Channel(Nil)` for timeout signaling
- does not follow the repo-wide signal-channel rule from the concurrency skill

Conclusion:

- normalize this as part of the shared concurrency cleanup
- use it as the standard timeout/cancellation helper for new worker/pipeline code

### G. CPU-heavy graph insight paths

Files:

- `src/chiasmus/graph/insights.cr`
- `src/chiasmus/graph/facts.cr`

Current issues:

- they use `spawn`, which is concurrent but not truly parallel under default execution
- they are independent enough to be good `ExecutionContext::Parallel` candidates later

Conclusion:

- do not touch these first
- benchmark first, then consider an opt-in `ExecutionContext` path behind compile flags

## Existing Good Patterns To Preserve

### Keep: actor/coalescing services

- `src/chiasmus/solvers/session.cr`
- `src/chiasmus/graph/parser_service.cr`
- `src/chiasmus/graph/grammar_manager.cr`

These are the right pattern for owned state and non-thread-safe resources.

### Keep: tool-level bounded dispatch

- `src/chiasmus/mcp_server/server.cr`

`ToolDispatcher` is already the correct outer request-shaping mechanism. The next step is to make the internal work paths reuse shared bounded workers instead of each tool re-implementing them.

## Recommended Architecture

### Phase 1 primitive: shared bounded work pool

Add a small utility module, likely under `src/chiasmus/utils/` or `src/chiasmus/concurrency/`.

It should support three shapes:

1. `map_ordered(items, max_concurrent, &block) : Array(U)`
2. `map_ordered_or_raise(items, max_concurrent, &block) : Array(U)`
3. `each_result(items, max_concurrent, &block) : Channel(ResultEnvelope(T))`

`ResultEnvelope` should carry:

- source index
- source item or key if needed
- result value
- error

Design requirements:

- one terminal envelope per input
- bounded worker count
- collector can drain fully before raising
- no hidden fire-and-forget work
- `Channel(Bool)` for slots/signaling

This primitive should replace:

- `Graph::FileIO` internals
- `Parity.parallel_map`
- the local bounded-pool logic in `Discovery::Pipeline`
- any future file enumeration worker in `SearchTool`

### Phase 2 adapters: file-path work helpers

Once the primitive exists, keep narrow convenience wrappers:

- `read_source_files_parallel`
- `read_source_files_or_raise`
- `read_search_files_parallel`

But they should only adapt item-level results into domain objects and warnings. They should not own concurrency logic.

### Phase 3 targeted pipelines

Add pipelines only where the stages differ enough to justify overlap.

#### Pipeline candidate 1: graph request path

`paths -> read/filter -> extract single-file graph -> merge -> optional cache persist`

Why:

- read and extract can overlap
- persist can trail the main response path if explicitly designed as bounded background work
- this path feeds multiple tools

Risk:

- merging and deduplication are central correctness points
- a too-generic pipeline here would complicate debugging

Recommendation:

- first implement as a simple linear pipeline, not a framework

#### Pipeline candidate 2: search request path

`paths -> stat/filter/read -> extract graph -> build corpus -> embed/query`

Why:

- file prep is currently fully sequential
- warnings and file inclusion decisions can be carried as stage outputs

Risk:

- embedding provider latency probably dominates on some runs
- full pipelining may not help unless we stream corpus creation

Recommendation:

- first parallelize path prep
- only pipeline deeper if measurement shows a win

## What We Should Not Do

- Do not create a generic concurrency framework with DSL-style stages.
- Do not switch the repo wholesale to `ExecutionContext` before the simpler worker-pool cleanup lands.
- Do not keep adding new local `spawn + semaphore + results` implementations.
- Do not make pipelines the default abstraction for everything; many call paths only need a bounded map.

## Benchmark and Analysis Plan

We need real measurements before phase 3 and before any `ExecutionContext` work.

### Add measurements for:

1. file-path preparation
   - sequential read/filter
   - bounded shared worker

2. graph extraction
   - current extractor
   - extractor on shared bounded worker
   - optional pipelined read/extract variant

3. search request path
   - current
   - parallelized file prep
   - optional pipelined prep + extraction

4. graph insights
   - default `spawn`
   - `ExecutionContext::Parallel` when compiled with flags

### Suggested outputs

- elapsed time
- file count
- bytes processed
- worker count
- hit/miss counts for cache
- warnings/error counts

### Likely place

- extend `scripts/measure.cr` or add `scripts/measure_concurrency.cr`

## TDD Rollout Plan

### Step 1. Introduce the shared bounded worker primitive

Red:

- spec that ordered results preserve input order
- spec that `max_concurrent` is respected
- spec that all results are drained before raising
- spec that one failed item does not strand other workers

Green:

- implement the primitive with `Channel(Bool)` and a result envelope

### Step 2. Refactor `Graph::FileIO` onto the primitive

Red:

- existing `parallel_io_spec`
- new spec for bounded concurrency using injected reader block

Green:

- keep the public API thin, move concurrency to shared utility

### Step 3. Replace `Parity.parallel_map`

Red:

- parity specs covering stable ordering and full completion

Green:

- delete duplicate pool logic

### Step 4. Refactor `Discovery::Pipeline`

Red:

- preserve no-timeout-on-failed-worker behavior
- preserve dedup semantics

Green:

- use the shared bounded primitive internally

### Step 5. Parallelize `SearchTool` file preparation

Red:

- warnings preserved
- oversized files skipped
- non-files skipped
- bounded concurrency respected

Green:

- move path work to shared primitive

### Step 6. Measure before deeper pipelines

Decision gate:

- if file prep is a meaningful fraction of end-to-end search/graph latency, continue to pipeline
- otherwise stop at the shared bounded worker refactor

### Step 7. Prototype one linear pipeline

Best first candidate:

- graph request path

Red:

- backpressure/bounded stage sizes
- output completeness under partial failures
- no leaked workers on early error

Green:

- keep it narrow and domain-specific

### Step 8. Optional `ExecutionContext` experiments

Only after:

- shared-state cleanup is complete
- default worker/pipeline design is stable
- measurements show CPU dominance

## Acceptance Criteria

We are done with the concurrency refactor when:

- there is one shared bounded work primitive used across the repo
- `parallel_io`, `parity`, and `discovery` no longer duplicate pool logic
- `search` no longer does sequential file prep
- signal/semaphore channels use `Channel(Bool)` in new code
- no worker path can hang because some inputs fail early
- benchmarks show whether deeper pipelines or `ExecutionContext` are justified

## Recommended Next Implementation Slice

1. land the shared bounded work primitive
2. move `Graph::FileIO` onto it
3. move `Parity.parallel_map` onto it
4. parallelize `SearchTool` path prep

That gives the repo one concurrency vocabulary before we decide whether deeper pipelines are worth the complexity.
