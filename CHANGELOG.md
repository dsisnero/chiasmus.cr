# Changelog

All notable changes to this project are documented in this file.

The format is based on Keep a Changelog, and the project uses semantic version tags.

## [Unreleased]

### Added

- Repo-local parity configuration support under `.chiasmus/config.yml`, including vendor/target path equivalence rules and shared atomic file writes for repo config persistence.
- Snapshot metadata headers in `chiasmus-facts` output plus focused specs for cached facts, parity snapshots, planner snapshots, completion artifacts, and repo-config startup behavior.
- Pure embedding-resolution helpers on `SearchTool` so provider selection can be asserted without invoking live embedding clients during tests.
- Focused MCP path-validation specs covering directory rejection and unwritable graph-cache fallback for `chiasmus_graph` and `chiasmus_map`.

### Changed

- `chiasmus-plan`, `chiasmus-parity`, and `chiasmus-complete` now reload cached `CodeGraph` snapshots from emitted facts files instead of rebuilding graph state from Prolog text alone.
- Parity matching now preserves qualified names, honors explicit `target_symbol` aliases, and can normalize source/target path layouts through repo parity configuration.
- Repo docs now point parity workflows at the installed `cross-language-crystal-parity` skill scripts instead of stale repo-local copies.
- `chiasmus_graph` and `chiasmus_map` now reject directory entries in `files` with a direct argument-validation error that tells callers to pass concrete source files.
- Watcher specs now synchronize on observed watcher state instead of relying on fixed sleeps, which makes file-create and file-modify assertions deterministic under load.

### Fixed

- MCP server startup now ensures the repo-local `.chiasmus/` directory exists without seeding parity settings into repos that are not using parity workflows.
- `chiasmus-complete` status and incomplete queries now share the same snapshot-backed parity inputs and exit cleanly under process-level and in-memory specs.
- Graph extraction now falls back to uncached extraction when the SQLite graph cache is unavailable or unwritable, instead of collapsing MCP requests into `Channel is closed`.
- Search embedding-provider specs no longer hang or touch real provider paths when validating environment-driven provider selection.
- Watcher unit and watcher/cache integration specs no longer race initial scans or grammar bootstrap during file-system event assertions.

## [0.3.0] - 2026-06-28

### Added

- Dedicated binaries for the MCP server, discovery, grammar management, parity reporting, and the interactive agent CLI.
- In-memory MCP healthcheck support for validating `initialize` plus `tools/list` without spawning an external client.
- Async execution boundaries across MCP tool paths for verification, graph analysis, discovery, and skill persistence.
- Semantic code search backed by extracted graph data and embedding providers.
- Structured review-plan generation through `chiasmus_review`.
- Grammar-management workflows for install, compile, update, cleanup, and batch operations.

### Changed

- MCP startup now degrades gracefully when no LLM backend is configured instead of failing the whole server.
- Default LLM configuration now resolves to the DeepSeek provider family unless the model implies a different provider.
- Review plans now formalize real problem statements, preserve delta-review context, and generate more actionable phase instructions.
- The server version is derived from `shard.yml` so the shard version, startup banner, and CLI `--version` stay aligned.

### Fixed

- MCP tool dispatch now respects cancellation boundaries and server-scoped state.
- No-LLM server setup now refreshes correctly from environment-backed configuration when LLM-dependent tools become available.
- Bounded file reads and async error propagation are preserved across discovery, graph, and parity entry points.
- Formalize and solve fallbacks now behave correctly when only the non-LLM template path is available.
