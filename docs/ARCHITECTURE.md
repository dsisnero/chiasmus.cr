# Architecture

## Overview

Chiasmus.cr is a behavior-faithful Crystal port of the chiasmus MCP server with enhanced LLM integration via Crig. The architecture consists of:

1. **MCP Server Core** - Model Context Protocol server implementation using `spider-gazelle/mcp.cr`
2. **Formal Verification Engine** - Integrates Z3 SMT solver (`taw/crystal-z3`) and SWI-Prolog (`dsisnero/crolog`)
3. **Code Analysis Pipeline** - Tree-sitter-based source code parsing with multi-language walkers (`dsisnero/crystal-tree-sitter`)
4. **LLM Integration** - Crig agent with multi-provider support (DeepSeek, OpenAI, etc.)
5. **Template System** - Problem formalization via reusable templates

## Current Implementation

### Module Structure

```
src/chiasmus/
├── chiasmus.cr            # Main entry point and CLI
├── server_factory.cr      # Server factory pattern
├── rig_tool.cr           # Crig agent implementation
├── graph/                # Tree-sitter analysis
│   ├── parser.cr        # Multi-language parser
│   ├── extractor.cr     # Fact extraction from AST
│   ├── walkers.cr       # Language-specific AST walkers (Crystal, Python, Go, Clojure, generic)
│   ├── tree_sitter_extensions.cr  # Patched tree-sitter methods
│   └── analyses/        # Analysis implementations
├── solvers/             # Formal verification
│   ├── z3_solver.cr    # Z3 SMT solver integration
│   ├── prolog_solver.cr # SWI-Prolog integration
│   ├── prolog_cr_solver.cr # Crystal Prolog solver
│   └── hybrid_solver.cr # Combined solver orchestration
├── mcp_server/          # MCP server implementation
│   ├── server.cr       # MCP server core
│   └── tools/          # MCP tools (10+ tools for code analysis)
├── llm/                 # LLM integration
│   ├── driver.cr       # LLM driver interface
│   ├── crig_driver.cr  # Crig implementation
│   └── types.cr        # LLM types and prompts
└── utils/              # Utilities
    ├── config.cr       # Configuration management
    └── logging.cr      # Structured logging
```

### Dependencies

**Core Dependencies:**
- `mcp` (`spider-gazelle/mcp.cr`) - Model Context Protocol implementation
- `tree_sitter` (`dsisnero/crystal-tree-sitter`) - Tree-sitter bindings (patched for null safety)
- `z3` (`taw/crystal-z3`) - Z3 SMT solver bindings
- `crolog` (`dsisnero/crolog`) - SWI-Prolog integration (patched with missing bindings)
- `crig` (`dsisnero/crig`) - LLM driver with multi-provider support

**Development Dependencies:**
- `ameba` - Code linting and style checking
- `json-schema` - JSON schema validation for MCP

### Concurrency Model

Crystal uses fibers for lightweight concurrency:
- `spawn` for non-blocking operations (LLM calls, Prolog queries)
- `Channel` for communication between fibers
- Go/Crystal concurrency patterns for MCP server responsiveness
- Non-blocking I/O for all external calls (LLM, Prolog, Z3)

### Key Design Decisions

1. **Upstream Behavior as Source of Truth** - Port behavior first, then express with Crystal idioms
2. **Inventory-First Porting** - All work tracked in `plans/inventory/` manifests
3. **Test Parity** - Upstream tests ported as Crystal specs (57 examples, 0 failures)
4. **Continuous Verification** - Quality gates (`format`, `ameba`, `spec`) run frequently
5. **Shard Patching** - Fork and patch dependencies when needed (crolog, tree_sitter)

## Technology Stack

### Formal Verification
- **Z3 SMT Solver**: Mathematical proof of program properties via `crystal-z3`
- **SWI-Prolog**: Logic programming via patched `crolog` shard
- **Hybrid Solving**: Combined Z3 + Prolog for complex verification tasks

### Code Analysis
- **Tree-sitter**: Multi-language parsing with language-specific walkers
- **Crystal Walker**: Custom walker for Crystal code analysis
- **Fact Extraction**: AST traversal to build knowledge graphs
- **Call Graph Analysis**: Reachability, dead code, impact analysis

### LLM Integration
- **Crig Agent**: Multi-provider LLM support (DeepSeek, OpenAI, etc.)
- **MCP Server**: Standardized LLM tool access protocol
- **Interactive REPL**: Agent-driven problem solving loop

### Performance Considerations
- **Fiber-based Concurrency**: Lightweight compared to OS threads
- **Non-blocking I/O**: All external calls use async patterns
- **Memory Safety**: Crystal's compile-time checks prevent common errors
- **Native Extensions**: C bindings for Z3 and SWI-Prolog for performance

## Porting Status

**Completed:**
- ✅ Core MCP server architecture
- ✅ Tree-sitter integration with multi-language walkers
- ✅ Z3 solver integration
- ✅ SWI-Prolog integration (with patched crolog)
- ✅ Crig LLM agent with DeepSeek support
- ✅ Test suite (57 examples, 0 failures)

**In Progress:**
- 🔄 Template system and problem formalization
- 🔄 Advanced call graph analysis
- 🔄 Integration testing with real LLM providers

**Upstream Reference:** See `vendor/chiasmus/` for original TypeScript implementation.