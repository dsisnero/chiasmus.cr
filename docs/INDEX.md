# Chiasmus.cr Documentation

## 📖 Table of Contents

### Core Documentation
- **[ARCHITECTURE.md](ARCHITECTURE.md)** - System architecture and design decisions
- **[DEVELOPMENT.md](DEVELOPMENT.md)** - Development setup and workflow
- **[TESTING.md](TESTING.md)** - Testing strategy and guidelines
- **[CODING-GUIDELINES.md](CODING-GUIDELINES.md)** - Code style and conventions
- **[PR-WORKFLOW.md](PR-WORKFLOW.md)** - Pull request workflow

### Agent Engineering
- **[../AGENTS.md](../AGENTS.md)** - Agent engineering guide and porting workflow
- **[../CLAUDE.md](../CLAUDE.md)** - Project overview and development guidelines

### Technical Reference
- **[swi_prolog/](swi_prolog/)** - SWI-Prolog integration documentation
- **[../plans/inventory/](../plans/inventory/)** - Porting inventory and parity tracking
- **[../lib_issues/](../lib_issues/)** - Shard patch tracking

## 🎯 Quick Links

### Getting Started
- [Installation](../README.md#-quick-start)
- [Usage Examples](../README.md#-usage)
- [Development Setup](../README.md#-development)

### Architecture
- [Technology Stack](../README.md#-architecture--technology-stack)
- [Project Structure](../README.md#-project-structure)
- [Porting Status](../README.md#-porting-status)

### Contributing
- [Porting Guidelines](../README.md#porting-guidelines)
- [Quality Gates](../README.md#quality-gates)
- [Language Mapping](../README.md#language-mapping-typescript--crystal)

## 🔍 Detailed Topics

### Formal Verification
- **Z3 SMT Solver**: Mathematical proof of program properties
- **SWI-Prolog**: Logic programming and rule-based reasoning
- **Problem Formalization**: Natural language to formal logic translation

### Code Analysis
- **Tree-sitter**: Multi-language source code parsing
- **Call Graph Analysis**: Reachability, dead code, impact analysis
- **Fact Extraction**: AST traversal for knowledge graph construction

### LLM Integration
- **MCP Server**: Model Context Protocol implementation
- **Crig Agent**: Multi-provider LLM support (DeepSeek, OpenAI, etc.)
- **Interactive REPL**: Agent-driven problem solving

## 📚 External Resources

- **[Upstream chiasmus](https://github.com/yogthos/chiasmus)** - Original TypeScript implementation
- **[Crystal Language](https://crystal-lang.org/)** - Official Crystal documentation
- **[Crig](https://github.com/dsisnero/crig)** - LLM driver library
- **[Crolog](https://github.com/dsisnero/crolog)** - SWI-Prolog bindings (patched)
- **[Tree-sitter](https://github.com/dsisnero/crystal-tree-sitter)** - Source code parsing (patched)

## 🆘 Support

- **GitHub Issues**: [Report bugs or request features](https://github.com/dsisnero/chiasmus.cr/issues)
- **Agent Guidance**: See [AGENTS.md](../AGENTS.md) for engineering workflows
- **Porting Questions**: Check [plans/inventory/](../plans/inventory/) for parity status