# Testing Guide

## Testing Philosophy

This repo is a porting project and an MCP runtime. The tests therefore need to prove two things:

1. Crystal behavior matches the intended upstream behavior
2. the server still works as an actual MCP tool host

That is why the suite spans both low-level unit coverage and full in-memory MCP flows.

## What Gets Tested

### CLI and entrypoints

These specs check:

- `--version`
- `--healthcheck`
- CLI help output
- executable entrypoint behavior

### MCP transport and tool registration

These specs cover:

- `initialize`
- `tools/list`
- tool gating when optional backends are missing
- cancellation boundaries
- end-to-end tool execution over in-memory transports

### Formalization and solver flows

These specs exercise:

- template lookup
- solve/fallback behavior
- linting
- Z3 execution
- Prolog execution
- learning and skill persistence behavior

### Graph, discovery, and parser flows

These specs cover:

- discovery CLI behavior
- parser and grammar loading
- call-graph extraction
- graph algorithms
- snapshot diffing
- concurrency-sensitive file and parser paths

### Search and review

These specs cover:

- semantic-search corpus generation
- embedding cache behavior
- review-plan generation and delta-review handling

### Parity tooling

These specs verify the inventory and manifest helpers that keep the Crystal port aligned with upstream.

## Core Commands

Run the repo gates:

```bash
make format
make lint
make test
```

## Focused Test Runs

Examples that are useful during development:

```bash
crystal spec spec/mcp_server/tools/formalize_spec.cr
crystal spec spec/mcp_server/tools/solve_spec.cr
crystal spec spec/chiasmus/review_spec.cr
crystal spec spec/mcp_server/mcp_integration_spec.cr
crystal spec spec/chiasmus/graph/
```

If you want the same cache behavior used in most local verification passes:

```bash
CRYSTAL_CACHE_DIR=$PWD/.crystal-cache crystal spec spec/mcp_server/tools/formalize_spec.cr
```

## Release-Oriented Verification

Before tagging a release, verify at least these:

```bash
make lint
make test
./bin/chiasmus --healthcheck
./bin/chiasmus-agent --help
./bin/chiasmus-discover --help
./bin/chiasmus-grammar --help
./bin/chiasmus-parity --help
```

That mix validates both the library and the distributed binaries.

## Reading Failures

A few failure patterns are common:

- MCP breakage often appears first in `initialize` or `tools/list` tests
- no-LLM regressions usually show up in formalize/solve/learn behavior or tool gating
- graph regressions often come from grammar lookup, parser availability, or shared-state assumptions
- semantic-search regressions often come from embedding provider resolution or cached vector shape mismatches

## Notes for Contributors

- Prefer adding a focused spec before changing behavior.
- If a bug depends on concurrency, preserve that shape in the regression test instead of rewriting it into a synchronous example.
- If the behavior comes from upstream, keep the assertion language aligned with the upstream contract.
