# Development Guide

## Prerequisites

- Crystal `>= 1.19.1`
- SWI-Prolog
- Z3
- tree-sitter CLI
- git with submodule support

Typical macOS setup:

```bash
brew install swi-prolog z3 tree-sitter
```

Typical Ubuntu setup:

```bash
sudo apt-get install swi-prolog z3
npm install -g tree-sitter-cli
```

## Repository Setup

```bash
git clone --recursive https://github.com/dsisnero/chiasmus.cr.git
cd chiasmus.cr
shards install
```

If you cloned without submodules:

```bash
git submodule update --init --recursive
```

## Daily Commands

### Quality gates

```bash
make format
make lint
make test
```

### Build binaries

```bash
make build
make build-clis
```

### Runtime smoke checks

```bash
./bin/chiasmus --healthcheck
./bin/chiasmus-agent --help
./bin/chiasmus-discover --help
./bin/chiasmus-grammar --help
./bin/chiasmus-parity --help
```

## Runtime Configuration

### LLM-backed workflows

The main server factory reads environment variables at startup.

Common variables:

```bash
export CHIASMUS_LLM_PROVIDER=deepseek
export CHIASMUS_LLM_MODEL=deepseek-chat
export DEEPSEEK_API_KEY=...
```

Important behavior:

- default provider family: DeepSeek
- provider may be inferred from the model name
- when the provider key is missing, the server still starts in no-LLM mode

No-LLM mode keeps graph and verification tools available while gating the truly LLM-only learning path.

### Embedding-backed search

Semantic search needs embedding credentials:

```bash
export CHIASMUS_EMBED_PROVIDER=openai
export CHIASMUS_EMBED_MODEL=text-embedding-3-small
export OPENAI_API_KEY=...
```

## Project Workflows

### MCP server work

When changing anything under `src/chiasmus/mcp_server/`:

1. run the tool-focused specs first
2. run `./bin/chiasmus --healthcheck`
3. rerun the broader integration specs before release

The healthcheck is especially useful because it exercises tool registration, transport connection, and `tools/list`.

### Graph and parser work

When changing anything under `src/chiasmus/graph/` or `src/chiasmus/discovery/`:

1. verify grammar lookup assumptions
2. run focused graph/discovery specs
3. confirm the discovery and grammar CLIs still behave as expected

Useful commands:

```bash
./bin/chiasmus-discover --help
./bin/chiasmus-grammar status --verbose
```

### Formalization and solver work

When changing anything under `src/chiasmus/formalize/`, `src/chiasmus/skills/`, or `src/chiasmus/solvers/`:

1. run focused formalize/solve/learn/verify specs
2. confirm fallback behavior without an LLM when relevant
3. check that linting and correction-loop behavior still match expectations

## Porting Workflow

This repo treats `vendor/chiasmus` as the behavioral source of truth.

Standard loop:

1. read the upstream implementation and tests first
2. update the parity inventory if the scope changes
3. port tests or characterization specs early
4. make the smallest behavior-faithful code change
5. rerun focused checks
6. finish with the repo gates

Relevant references:

- [../AGENTS.md](../AGENTS.md)
- [../plans/parity.md](../plans/parity.md)
- [../plans/inventory/](../plans/inventory/)

## Grammar Management

The supported workflow is the `chiasmus-grammar` CLI, not ad-hoc manual parser copying.

Examples:

```bash
./bin/chiasmus-grammar list
./bin/chiasmus-grammar status --verbose
./bin/chiasmus-grammar setup --force
./bin/chiasmus-grammar compile python
```

Grammar lookup prefers:

1. `CHIASMUS_GRAMMAR_DIR`
2. bundled `./grammars`
3. XDG cache
4. project-local grammar directories when available

## Debugging Notes

Useful commands:

```bash
crystal spec --verbose
crystal spec --fail-fast
crystal tool context
```

Common realities of this repo:

- some solver specs print diagnostic output as part of the underlying tools
- MCP startup issues often show up first in `--healthcheck`
- graph regressions often come from grammar lookup, parser availability, or shared-state assumptions

## Dependency Issue Tracking

If a problem is caused by a shard or upstream library rather than Chiasmus itself, record it under [../shards_issues/](../shards_issues/).

Those notes are useful when:

- a local workaround exists
- the upstream bug is reproducible in isolation
- a future dependency update should retire the workaround

## Release Flow

For a normal release:

1. update `shard.yml` version
2. update `CHANGELOG.md`
3. update release-facing docs
4. run the local gates
5. commit the release
6. create and push a `v*` tag

Pushing a `v*` tag triggers `.github/workflows/release.yml`, which builds and publishes platform artifacts.
