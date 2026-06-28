# Architecture

## System Overview

Chiasmus.cr is split into five cooperating layers:

1. MCP serving and CLI entrypoints
2. Formalization and solver execution
3. Graph extraction and analysis
4. Search and review orchestration
5. Grammar and parity support tooling

The core runtime is `src/chiasmus/`. Top-level executables in `src/` expose different workflows against that shared library.

## Runtime Modes

### `chiasmus`

The main binary runs the MCP server.

- default transport: stdio
- debug transport: streamable HTTP
- diagnostics: `--healthcheck`

The healthcheck is not a stub. It creates an in-memory client/server pair, performs a real `initialize`, then requests `tools/list`. That catches startup breakage in server registration, transport wiring, and tool advertisement.

### `chiasmus-agent`

The agent CLI is a local operator tool. It can combine code graph context and formal solving without going through MCP transport.

### `chiasmus-discover`

The discovery CLI extracts source-level inventory data in a TSV format that parity tooling can consume.

### `chiasmus-grammar`

The grammar manager owns install, compile, update, status, and cleanup operations for parser assets.

### `chiasmus-parity`

The parity CLI reads curated inventory plus optional conversion rules and reports the current Crystal-vs-upstream status.

## MCP Server Design

The server core lives in `src/chiasmus/mcp_server/server.cr`.

Responsibilities:

- construct and register tool definitions
- keep per-server tool handlers
- expose healthcheck and streamable transport helpers
- isolate cancellation-aware async execution
- gate capability-dependent tools when a required backend is missing

Current tool surface:

- verification: `chiasmus_verify`
- template discovery and authoring: `chiasmus_skills`, `chiasmus_formalize`, `chiasmus_craft`, `chiasmus_learn`
- solver workflow: `chiasmus_solve`
- graph and review: `chiasmus_graph`, `chiasmus_map`, `chiasmus_review`
- retrieval: `chiasmus_search`
- direct provider prompt: `chiasmus_crig`
- spec cleanup: `chiasmus_lint`

## LLM Configuration Model

The LLM layer is centered on `src/chiasmus/llm/types.cr` and `src/chiasmus/server_factory.cr`.

Key behaviors:

- `shard.yml` is the version source of truth, but provider and model come from environment variables at runtime.
- The default provider family is DeepSeek.
- If the provider is blank and only a model name is given, the provider is inferred from the model prefix or naming pattern.
- When no LLM backend is available, the factory returns a no-LLM server instead of aborting startup.

That no-LLM mode is intentional. It keeps the graph and direct verification workflows usable on machines without API keys.

## Formalization and Solvers

The formal side is split across:

- `src/chiasmus/formalize/`
- `src/chiasmus/skills/`
- `src/chiasmus/solvers/`

### Formalization

The formalization engine selects a reusable template from the skill library, fills it through an agent-backed workflow when available, and returns either:

- a ready-to-verify spec
- a template skeleton plus instructions for manual filling

### Solver adapters

The solver layer supports:

- Z3 via SMT-LIB
- SWI-Prolog via `crolog`

The server keeps these responsibilities separated:

- `chiasmus_lint`: structural cleanup only
- `chiasmus_formalize`: template selection only
- `chiasmus_verify`: actual solver execution
- `chiasmus_solve`: orchestration across all of the above

## Graph Extraction and Analysis

The graph subsystem lives under `src/chiasmus/graph/`.

Major components:

- `parser_service.cr`: parser lifecycle and shared loading behavior
- `extractor.cr`: graph extraction from parsed source
- `walkers/*.cr`: language-specific AST walkers
- `analyses.cr`: graph algorithms and analysis dispatch
- `map.cr`: compact graph projection for LLM consumption
- `diff.cr`: snapshot-based delta reporting
- `parallel_io.cr`: bounded concurrent file reads

Graph extraction is designed for overlapping requests. Files are read and parsed with bounded concurrency instead of serializing the whole workload through one request path.

## Search and Review

### Search

`src/chiasmus/search/engine.cr` builds an embedding corpus from extracted defines and nearby source snippets. Search then ranks hits by cosine similarity.

Supporting pieces:

- `embedding_cache.cr`: avoid recomputing vectors for unchanged content
- `vector_store.cr`: schema-aware persistence and validation
- `code_index.cr`: higher-level indexing pipeline

### Review

`src/chiasmus/review.cr` does not execute a review itself. It builds a phased plan that tells an LLM which Chiasmus tools and templates to run.

That plan can include:

- overview and architecture passes
- taint, authorization, and resource-safety checks
- correctness and boundary-condition checks
- delta-aware review against saved graph snapshots

## Concurrency Model

The codebase assumes overlapping MCP requests.

Common patterns:

- `spawn` + `Channel(T)` for long-running work
- `Mutex` for shared mutable caches and registries
- actor-style isolation for resources that are not fiber-safe
- bounded concurrency helpers for file and extraction workloads

Important subsystems already built around this model:

- graph discovery and extraction pipelines
- parser service loading and waiter coalescing
- MCP tool execution boundaries
- solver and learner async wrappers

## Grammar and Language Support

Language metadata is centralized in `src/chiasmus/graph/language_registry.cr`.

The registry tracks:

- grammar package name
- preferred install method
- file extensions
- grammar dependencies
- special wasm-backed cases

That registry feeds grammar-management workflows and discovery/parser selection.

## Repository Map

```text
src/
├── chiasmus_cli.cr
├── chiasmus-agent.cr
├── chiasmus_discover.cr
├── chiasmus_grammar.cr
├── chiasmus_parity.cr
└── chiasmus/
    ├── formalize/
    ├── graph/
    ├── llm/
    ├── mcp_server/
    ├── search/
    ├── skills/
    ├── solvers/
    └── utils/
```

For development and release workflows, see [DEVELOPMENT.md](DEVELOPMENT.md).
