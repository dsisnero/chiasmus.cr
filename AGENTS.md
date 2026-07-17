# Agent Engineering Guide

## Project Overview

This repository is a Crystal port of [yogthos/chiasmus](https://github.com/yogthos/chiasmus), an MCP server for formal verification with Z3 SMT solver, Tau Prolog, and tree-sitter-based source code analysis.

## Technology Stack

- **LLM Driver**: Using `crig` (`dsisnero/crig`) as the LLM driver with its native API. The upstream TypeScript LLM adapters (Anthropic, OpenAI-compatible, mock) are **not ported** — Crig replaces all of them. See `src/chiasmus/llm/` for the Crig-based wrapper and `src/chiasmus/server_factory.cr` for provider-specific factory methods (OpenAI, DeepSeek, Anthropic, Gemini, Groq, Ollama, Mistral, Cohere, Azure).
- **Prolog Integration**: Using `crolog` to drive SWI-Prolog
- **Concurrency**: Ensure non-blocking operations using Go/Crystal concurrency patterns (spawn, channels, fibers)

**Important**: When implementing LLM or Prolog interactions, use non-blocking patterns to maintain system responsiveness. Prefer Crystal's `spawn` for concurrent operations and `Channel` for communication between fibers.

## Concurrency Design

**All new methods must assume multiple fibers may call them concurrently.** The MCP server handles multiple clients; graph extraction, search, and analysis can run in overlapping fibers.

### Standing Rules

1. **No shared mutable state without synchronization.** Prefer `Mutex` for guarded access, `Atomic` for counters, `Channel` for communication.
2. **Long-running operations return `Channel(T)`** — never block the calling fiber. See `discovery/pipeline.cr` for the canonical bounded-concurrency pattern.
3. **Non-thread-safe resources get actor/worker fibers** — see `solvers/session.cr` (single Prolog worker fiber) and `parser_service.cr` (waiter coalescing for grammar loading).
4. **Wire new code for concurrency immediately** — writing synchronous code that "we'll parallelize later" creates hidden data races when someone else spawns it.

### Concurrency Primitives (in priority order)

| Primitive | When to Use |
|-----------|-------------|
| `Channel(T)` + `spawn` | All long-running I/O or CPU work. Return a channel, receive in the caller. |
| `Mutex` | Guard shared mutable state (singletons, caches, counters accessible from multiple fibers). |
| `Atomic` | Lock-free counters and flags. |
| `WaitGroup` | Coordinate N parallel fibers before proceeding. |
| `select` / `when` | Multi-channel wait with timeout. See `utils/timeout.cr`. |

### Existing Concurrent Subsystems

| Subsystem | Pattern | Reusable For |
|-----------|---------|-------------|
| `discovery/pipeline.cr` | Bounded semaphore + per-item `spawn` + result `Channel` | Parallel file processing |
| `solvers/session.cr` | Actor/worker queue | Isolating non-thread-safe resources |
| `parser_service.cr` | Waiter coalescing + broadcast | Deduplicating concurrent requests |
| `grammar_manager.cr` | Async lifecycle via `Channel(BoolResult)` | Any long-running setup/teardown |
| `utils/timeout.cr` | `Channel` + `select` + timeout | Any operation with a deadline |

### Known Bottleneck: `Graph::Extractor.extract_graph`

The #1 missing concurrency opportunity. Currently processes N files **sequentially** in a single fiber despite each file being independently parseable. The `discovery/pipeline.cr` bounded-concurrency pattern is the template for parallelizing this. Target: P21 (parallel graph extraction).

**Key divergence from upstream**: The upstream `src/llm/` and `src/solvers/prolog-solver.ts` constants are replaced by Crig and crolog respectively. These are marked as `intentional_divergence` in the port inventory and do not require porting.

## Source of Truth

The upstream source is pinned as a git submodule at `vendor/chiasmus` (tracking `main` branch).

**Upstream behavior is the source of truth.** Port behavior first, then express it with Crystal idioms.

## Quality Gates

Run these commands to ensure code quality:

```bash
make format    # crystal tool format --check src spec
make lint      # ameba src spec
make test      # crystal spec
```

## Porting Workflow

1. **Inventory-first**: All porting work must be tracked in `plans/inventory/` manifests
2. **Behavior faithfulness**: Preserve upstream semantics exactly (parameter order, edge cases, error behavior)
3. **Test parity**: Port upstream tests as Crystal specs early in the process
4. **Continuous verification**: Run quality gates frequently during development

## Agent Execution

- For all coding tasks, use judgment to choose an appropriate lower-power model and run that work in a subagent first.

## Implementation Skills

Use these skills for different aspects of the port:

| Task | Skill |
|------|-------|
| General porting workflow | `porting-to-crystal` |
| Source API/test inventory, drift checks | `cross-language-crystal-parity` |
| Crystal shard selection/replacement | `find-crystal-shards` |
| Local edits under `./lib` shard sources | `crystal-shard-lib-patch` |

## Language Mapping (TypeScript → Crystal)

| TypeScript | Crystal |
|------------|---------|
| `interface` | `abstract struct` or module with methods |
| `class` | `class` |
| `type` | `alias` or `struct` |
| `function` | `def` |
| `Promise<T>` | `Future(T)` or `Channel(T)` |
| `async/await` | `spawn` + `Channel` or `Future` |
| `try/catch` | `begin/rescue` |
| `export` | Make method/class public in module |
| `import` | `require` |

## Common Patterns

- Use `Bytes` (`Slice(UInt8)`) for binary data, not `String`
- Preserve numeric types explicitly (`_u8`, `_i32`, etc.) where behavior depends on signedness/range
- Map TypeScript `Map<K, V>` to Crystal `Hash(K, V)`
- Map TypeScript `Array<T>` to Crystal `Array(T)`
- Map TypeScript `Set<T>` to Crystal `Set(T)`

## Completion Criteria

A ported unit is complete when:

1. API surface is translated and wired
2. Relevant upstream tests are ported as Crystal specs
3. Crystal quality gates pass (`format`, `ameba`, `spec`)
4. Parity outputs/fixtures match upstream expectations
5. Cross-language parity checks pass
6. Documentation reflects completion status and any unavoidable deviations

## Vendor Directories (`vendor/`)

Use these with DeepWiki (`deepwiki_ask_question repoName: "owner/repo"`) to research implementation patterns:

| Directory | DeepWiki Repo | Description |
|-----------|---------------|-------------|
| `chiasmus/` | `yogthos/chiasmus` | **Main upstream** — TypeScript MCP server for formal verification with Z3, Tau Prolog, tree-sitter source analysis. **This is the porting source of truth.** |
| `codeium-parse/` | `Exafunction/codeium-parse` | CLI parsing tool built on tree-sitter with prepackaged grammars for many languages (C, C++, Go, Java, Python, TS, Ruby, PHP, Kotlin, Dart, Bash, Protobuf). |
| `coderlm/` | `JaredStewart/coderlm` | CodeRLM — Rust server indexing codebases via tree-sitter, exposes JSON API for LLM agents (symbols, callers, tests, grep). |
| `maki/` | `tontinton/maki` | Maki — Rust TUI AI coding agent optimised for minimal context token usage, using tree-sitter for compact file indexing. |
| `merkletree/` | `pratikpandey21/merkletree` | Minimal Go Merkle Tree implementation (SHA-256). |
| `openapi_cr/` | `dsisnero/openapi_cr` | Crystal port of Microsoft Kiota — OpenAPI parser, URL-tree resource grouper, codegen AST builder, Crystal API client generator. |
| `syntastica/` | `RubixDev/syntastica` | Rust syntax highlighting library using tree-sitter with three highlighting modes, theme system, query preprocessing, and Node.js bindings. |
| — | `xberg-io/tree-sitter-language-pack` | Monorepo of tree-sitter grammars for 30+ languages with consistent npm/shared-obj publishing, WASM builds, and metadata. Useful for borrowing grammar loading patterns, WASM integration, and parser lifecycle approaches. |

**When investigating tree-sitter grammar loading**: query `RubixDev/syntastica` (Rust reference), `Exafunction/codeium-parse` (packaged grammars), and `xberg-io/tree-sitter-language-pack` (grammar monorepo patterns) for ideas. The main `yogthos/chiasmus` upstream is the porting source of truth — query it first before other vendors.

## Getting Started

1. Review the upstream source in `vendor/chiasmus/`
2. Check `plans/inventory/` for existing parity tracking
3. Use `cross-language-crystal-parity` to bootstrap/validate the parity plan
4. Implement against inventory items using `porting-to-crystal` workflow
