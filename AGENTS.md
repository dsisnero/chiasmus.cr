# Agent Engineering Guide

## Project Overview

This repository is a Crystal port of [yogthos/chiasmus](https://github.com/yogthos/chiasmus), an MCP server for formal verification with Z3 SMT solver, Tau Prolog, and tree-sitter-based source code analysis.

## Technology Stack

- **LLM Driver**: Using `crig` as the LLM driver with the crig API (not vendor API)
- **Prolog Integration**: Using `crolog` to drive SWI-Prolog
- **Concurrency**: Ensure non-blocking operations using Go/Crystal concurrency patterns (spawn, channels, fibers)

**Important**: When implementing LLM or Prolog interactions, use non-blocking patterns to maintain system responsiveness. Prefer Crystal's `spawn` for concurrent operations and `Channel` for communication between fibers.

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

## Getting Started

1. Review the upstream source in `vendor/chiasmus/`
2. Check `plans/inventory/` for existing parity tracking
3. Use `cross-language-crystal-parity` to bootstrap/validate the parity plan
4. Implement against inventory items using `porting-to-crystal` workflow