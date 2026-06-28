# Documentation Index

## Start Here

- [../README.md](../README.md): project overview, binaries, MCP tools, and quick start
- [../CHANGELOG.md](../CHANGELOG.md): shipped changes by release
- [../AGENTS.md](../AGENTS.md): repo-level engineering and concurrency rules

## Core Docs

- [ARCHITECTURE.md](ARCHITECTURE.md): runtime layers, server design, graph pipeline, solver flow, and concurrency model
- [DEVELOPMENT.md](DEVELOPMENT.md): setup, local workflows, grammar management, and release flow
- [TESTING.md](TESTING.md): test structure, focused runs, and release verification
- [CODING-GUIDELINES.md](CODING-GUIDELINES.md): Crystal and porting conventions
- [PR-WORKFLOW.md](PR-WORKFLOW.md): pull-request expectations and review checklist
- [adding_additional_language.md](adding_additional_language.md): extending grammar and discovery support

## Reference Material

- [../plans/parity.md](../plans/parity.md): curated parity roadmap
- [../plans/inventory/](../plans/inventory/): source, test, and port inventory artifacts
- [../shards_issues/](../shards_issues/): upstream shard and dependency issue notes
- [swi_prolog/README.md](swi_prolog/README.md): SWI-Prolog reference notes used during integration work

## Useful Entry Points In The Codebase

- `src/chiasmus.cr`: shared CLI/runtime entry
- `src/chiasmus_cli.cr`: MCP server executable
- `src/chiasmus/llm/types.cr`: provider and model resolution
- `src/chiasmus/server_factory.cr`: environment-backed server construction
- `src/chiasmus/mcp_server/server.cr`: tool registration, healthcheck, and transport wiring
- `src/chiasmus/review.cr`: review-plan builder
- `src/chiasmus/graph/`: parsing, extraction, graph algorithms
- `src/chiasmus/formalize/`: template-driven formalization flow
- `src/chiasmus/search/`: semantic-search indexing and retrieval

## Binaries

- `chiasmus`: MCP server
- `chiasmus-agent`: interactive graph-aware formal-solving CLI
- `chiasmus-discover`: parity/discovery extraction CLI
- `chiasmus-grammar`: grammar management CLI
- `chiasmus-parity`: parity reporting CLI
