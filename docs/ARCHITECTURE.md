# Architecture

## Overview

This is a Crystal port of the chiasmus MCP server. The original TypeScript architecture consists of:

1. **MCP Server Core** - Implements the Model Context Protocol server interface
2. **Formal Verification Engine** - Integrates Z3 SMT solver and Tau Prolog
3. **Code Analysis Pipeline** - Tree-sitter-based source code parsing and call graph extraction
4. **Template System** - Problem formalization via reusable templates
5. **Skill Library** - Repository of verification templates

## Porting Strategy

### Module Structure

The Crystal port will follow this module structure:

```
src/
├── chiasmus.cr              # Main entry point
├── mcp_server.cr           # MCP server implementation
├── verification/
│   ├── z3.cr              # Z3 SMT solver integration
│   ├── prolog.cr          # Tau Prolog integration
│   └── engine.cr          # Verification orchestration
├── analysis/
│   ├── tree_sitter.cr     # Tree-sitter bindings
│   ├── call_graph.cr      # Call graph extraction
│   └── analyzer.cr        # Analysis orchestration
├── templates/
│   ├── library.cr         # Template library
│   ├── formalizer.cr      # Problem formalization
│   └── crafter.cr         # Template creation
└── utils/
    ├── config.cr          # Configuration management
    └── logging.cr         # Structured logging
```

### Dependencies

Key Crystal shard dependencies needed:
- `mcp` - Model Context Protocol implementation
- `tree-sitter` bindings (to be selected)
- Z3 bindings (to be selected)
- Prolog implementation (to be selected)

### Concurrency Model

TypeScript uses async/await for concurrency. Crystal will use:
- `spawn` for lightweight concurrency
- `Channel` for message passing
- `Future` for async result handling

## Upstream Reference

See the upstream architecture documentation in `vendor/chiasmus/architecture.md`.