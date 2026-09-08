# Chiasmus.cr

[![CI](https://github.com/dsisnero/chiasmus.cr/actions/workflows/ci.yml/badge.svg)](https://github.com/dsisnero/chiasmus.cr/actions/workflows/ci.yml)

Crystal port of [yogthos/chiasmus](https://github.com/yogthos/chiasmus), built as an MCP server for formal verification and source-code analysis.

Chiasmus.cr combines:

- Z3 for SMT-based reasoning
- SWI-Prolog, driven through `crolog`, for graph and rule queries
- tree-sitter for multi-language code extraction
- `crig` for provider-backed LLM and embedding calls

The upstream TypeScript project in [vendor/chiasmus](vendor/chiasmus) remains the behavioral source of truth. This repo ports that behavior into Crystal and adds native binaries for MCP serving, grammar management, discovery, parity checking, and an interactive agent CLI.

## What It Does

At a high level, Chiasmus gives an LLM a toolbelt for turning vague questions into executable checks.

- `chiasmus_formalize` finds an existing formalization template and returns the skeleton, required slots, and instructions.
- `chiasmus_verify` runs either Z3 or Prolog on a filled-in spec and returns the actual solver result.
- `chiasmus_solve` runs the full loop: template selection, slot filling, linting, verification, and correction.
- `chiasmus_graph` parses source files with tree-sitter, extracts a call graph, and runs analyses such as reachability, dead-code detection, cycles, impact, and facts export.
- `chiasmus_search` builds an embedding corpus from extracted defines and performs semantic code search.
- `chiasmus_review` generates a structured review plan that tells an LLM which graph and verification steps to run and in what order.

This is useful when you want answers that are grounded in either:

- a formal proof or counterexample
- a concrete call path in real code
- a constrained, inspectable workflow rather than free-form speculation

## How It Works

### 1. MCP server lifecycle

The main `chiasmus` binary starts an MCP server over stdio by default. It can also run an HTTP streamable transport for debugging.

- `./bin/chiasmus`
- `./bin/chiasmus --healthcheck`
- `./bin/chiasmus --streamable --port 8899`

The healthcheck does a real in-memory MCP `initialize` plus `tools/list`, so it verifies the server’s actual runtime wiring instead of just checking that the process starts.

### 2. LLM-backed and no-LLM modes

LLM configuration comes from environment variables. The default provider is `deepseek`, and the model can also imply the provider when only a model name is given.

When an LLM backend is not configured, the server still starts:

- `chiasmus_formalize` falls back to template search
- `chiasmus_solve` falls back to the formalize path
- `chiasmus_learn` is gated from the tool listing because it truly requires an LLM

That design keeps the verification and graph-analysis parts useful even on machines without API keys.

### 3. Formal verification flow

The formal side has three layers:

1. A skill/template library describing reusable solver patterns
2. Tooling that selects and fills those templates
3. Solver adapters for Z3 and Prolog

Typical flow:

1. Ask `chiasmus_formalize` for a template matching the problem
2. Fill the returned slots with concrete declarations, rules, facts, or constraints
3. Run `chiasmus_verify`
4. Optionally use `chiasmus_learn` to extract a reusable template from a verified solution

### 4. Code analysis flow

The graph side parses files with language-specific walkers where available and a generic fallback otherwise.

Typical flow:

1. `chiasmus_graph` loads files and extracts defines/calls/facts
2. Graph algorithms answer reachability, callers, callees, cycles, impact, and dead-code questions
3. `chiasmus_map` projects a large graph into an LLM-friendly summary
4. `chiasmus_search` embeds the extracted defines for semantic lookup
5. `chiasmus_review` composes these pieces into a review recipe

Extraction is wired for concurrent use. Long-running operations are exposed through async boundaries internally so MCP requests can overlap without blocking the server loop.

## MCP Tools

The server currently exposes these tool families:

- `chiasmus_verify`: run Z3 or Prolog directly
- `chiasmus_skills`: search and inspect formalization templates
- `chiasmus_formalize`: pick a template for a natural-language problem
- `chiasmus_solve`: run the end-to-end solve loop
- `chiasmus_learn`: turn a verified solution into a reusable template
- `chiasmus_lint`: clean and validate a formal spec without executing it
- `chiasmus_graph`: extract and analyze call graphs
- `chiasmus_map`: return a compact codebase map
- `chiasmus_search`: semantic code search over extracted defines
- `chiasmus_craft`: author a new template and add it to the library
- `chiasmus_review`: generate a phased code-review plan
- `chiasmus_crig`: run a direct prompt against the configured LLM provider

## Included Binaries

`shard.yml` defines multiple targets:

- `chiasmus`: MCP server entrypoint
- `chiasmus-agent`: interactive CLI for graph-aware formal solving
- `chiasmus-discover`: tree-sitter discovery CLI for parity manifests
- `chiasmus-grammar`: grammar manager for install, compile, update, and cache operations
- `chiasmus-parity`: parity inventory reporter

## Quick Start

### Setup

```bash
git clone --recursive https://github.com/dsisnero/chiasmus.cr.git
cd chiasmus.cr
shards install
make build
make build-clis
make setup-grammars
```

### Verify the server

```bash
./bin/chiasmus --healthcheck
```

### Start the MCP server

```bash
./bin/chiasmus
```

### Run the agent CLI

```bash
./bin/chiasmus-agent --help
```

### Inspect grammar tooling

```bash
./bin/chiasmus-grammar --help
./bin/chiasmus-discover --help
./bin/chiasmus-parity --help
```

## Configuration

### LLM provider selection

Common environment variables:

```bash
export CHIASMUS_LLM_PROVIDER=deepseek
export CHIASMUS_LLM_MODEL=deepseek-chat
export DEEPSEEK_API_KEY=...
```

Supported provider families in the server factory include:

- `deepseek`
- `openai`
- `anthropic`
- `gemini`
- `groq`
- `ollama`
- `mistral`
- `cohere`

### Embeddings for semantic search

`chiasmus_search` uses embeddings plus cosine similarity over extracted defines.

Common environment variables:

```bash
export CHIASMUS_EMBED_PROVIDER=openai
export CHIASMUS_EMBED_MODEL=text-embedding-3-small
export OPENAI_API_KEY=...
```

The TypeScript upstream's `CHIASMUS_LOCAL_EMBED*` / `localEmbeddings` options
use the Node-only `node-llama-cpp` backend and are not supported by this Crystal
build. For local embeddings, run Ollama and configure
`CHIASMUS_EMBED_PROVIDER=ollama` with an embedding model such as
`nomic-embed-text`.

### Grammar installation and lookup

`shards install` downloads the `tree-sitter-manager` library only. It does not
build a dependency's executable target or put `tree-sitter-manager` on `PATH`.
`make build-clis` builds this project's manager-backed wrapper instead:

```bash
make build-clis
make setup-grammars
```

`make setup-grammars` installs Chiasmus's preinstalled baseline, including
Scheme and Common Lisp. Racket files use the Scheme grammar. To install only
those S-expression grammars, run:

```bash
./bin/chiasmus-grammar batch scheme,commonlisp
```

The wrapper delegates downloads, native builds, and cache management to
`tree-sitter-manager`; a checked-out grammar source tree or the separate
native `tree-sitter` command is not needed for normal installation. Use
`chiasmus-grammar compile LANGUAGE` only when intentionally compiling a local
grammar source under `./grammars`.

Graph extraction and discovery look for grammars in this order:

1. `CHIASMUS_GRAMMAR_DIR`
2. bundled `./grammars`
3. XDG cache directories
4. project grammar directories when available

The `chiasmus-grammar` binary is the supported way to manage those parser artifacts.

## Supported Analysis Surface

The graph subsystem has dedicated walkers for the primary languages Chiasmus is optimized around:

- Crystal
- TypeScript and TSX
- JavaScript
- Python
- Go
- Rust
- Java
- C#
- C++
- C
- Kotlin
- Scala
- Dart
- PHP
- Perl
- Bash
- Protobuf
- Clojure
- Scheme and Racket
- Common Lisp

The language registry also tracks additional languages and extensions for grammar management and future expansion.

## Repository Layout

```text
chiasmus.cr/
├── src/
│   ├── chiasmus_cli.cr         # MCP server executable entrypoint
│   ├── chiasmus-agent.cr       # Interactive agent CLI entrypoint
│   ├── chiasmus_discover.cr    # Discovery CLI entrypoint
│   ├── chiasmus_grammar.cr     # Grammar manager entrypoint
│   ├── chiasmus_parity.cr      # Parity CLI entrypoint
│   └── chiasmus/
│       ├── mcp_server/         # Server core and MCP tools
│       ├── graph/              # tree-sitter parsing and graph analyses
│       ├── formalize/          # Template selection and slot-filling flow
│       ├── solvers/            # Z3 and Prolog integrations
│       ├── llm/                # Provider config and adapters
│       ├── search/             # Embedding-based semantic search
│       └── skills/             # Template storage, relationships, learning
├── spec/                       # Crystal specs
├── docs/                       # Maintained prose docs
├── plans/                      # Parity and design plans
├── shards_issues/              # Notes for upstream shard/library bugs
└── vendor/chiasmus/            # Upstream TypeScript source of truth
```

## Development

Core local commands:

```bash
make format
make lint
make test
make build
make build-clis
```

For deeper guidance, use:

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
- [docs/TESTING.md](docs/TESTING.md)
- [docs/INDEX.md](docs/INDEX.md)
- [AGENTS.md](AGENTS.md)

## Release Notes and Issue Tracking

- [CHANGELOG.md](CHANGELOG.md) tracks shipped changes
- [shards_issues/](shards_issues/) tracks upstream dependency and shard issues that affect this repo

## License

MIT. See [LICENSE](LICENSE).
