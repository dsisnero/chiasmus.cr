# Changelog

All notable changes to this project are documented in this file.

The format is based on Keep a Changelog, and the project uses semantic version tags.

## [Unreleased]

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
