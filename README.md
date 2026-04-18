# Chiasmus.cr

[![CI](https://github.com/dsisnero/chiasmus.cr/actions/workflows/ci.yml/badge.svg)](https://github.com/dsisnero/chiasmus.cr/actions/workflows/ci.yml)
[![GitHub release](https://img.shields.io/github/v/release/dsisnero/chiasmus.cr)](https://github.com/dsisnero/chiasmus.cr/releases)

**Crystal port of [yogthos/chiasmus](https://github.com/yogthos/chiasmus)** - an MCP server for formal verification with Z3 SMT solver, Tau Prolog, and tree-sitter-based source code analysis.

**Upstream source pinned at:** `vendor/chiasmus` (git submodule tracking `main` branch)

Chiasmus.cr gives LLMs access to formal verification via Z3 (SMT solver) and SWI-Prolog, plus tree-sitter-based source code analysis. Translates natural language problems into formal logic using a template-based pipeline, verifies results with mathematical certainty, and analyzes call graphs for reachability, dead code, and impact analysis.

## 📚 Documentation

- **[AGENTS.md](AGENTS.md)** - Agent engineering guide and porting workflow
- **[CLAUDE.md](CLAUDE.md)** - Project overview and development guidelines
- **[docs/](docs/)** - Technical documentation
- **[plans/inventory/](plans/inventory/)** - Porting inventory and parity tracking
- **[vendor/chiasmus/README.md](vendor/chiasmus/README.md)** - Upstream documentation

## 🚀 Quick Start

### Installation

```bash
# Clone the repository
git clone https://github.com/dsisnero/chiasmus.cr.git
cd chiasmus.cr

# Install dependencies
shards install

# Initialize git submodules (upstream source)
git submodule update --init --recursive
```

### Usage

**As an MCP server:**
```bash
# Run as MCP server
./bin/chiasmus
```

**As a Crig agent (LLM integration):**
```bash
# Run as Crig agent with DeepSeek
CRIG_PROVIDER=deepseek ./bin/chiasmus --rig
```

**Interactive REPL:**
```bash
# Start interactive agent REPL
./bin/chiasmus --repl
```

## 🏗️ Architecture & Technology Stack

Chiasmus.cr is a behavior-faithful Crystal port with these key technology choices:

### Core Dependencies
- **[Crig](https://github.com/dsisnero/crig)** - LLM driver with multi-provider support (DeepSeek, OpenAI, etc.)
- **[Crolog](https://github.com/dsisnero/crolog)** - SWI-Prolog integration (patched for missing bindings)
- **[Z3](https://github.com/taw/crystal-z3)** - Z3 SMT solver bindings
- **[Tree-sitter](https://github.com/dsisnero/crystal-tree-sitter)** - Source code parsing (patched for null safety)
- **[MCP](https://github.com/spider-gazelle/mcp.cr)** - Model Context Protocol server implementation

### Concurrency Model
- **Crystal fibers** for lightweight concurrency
- **Non-blocking I/O** with `spawn` and `Channel` patterns
- **Go/Crystal concurrency patterns** for MCP server responsiveness

### Key Design Decisions
1. **Upstream behavior as source of truth** - Port behavior first, then express with Crystal idioms
2. **Inventory-first porting** - All work tracked in `plans/inventory/` manifests
3. **Test parity** - Upstream tests ported as Crystal specs early in process
4. **Continuous verification** - Quality gates (`format`, `ameba`, `spec`) run frequently

## 🔧 Development

### Quality Gates
```bash
make format    # crystal tool format --check src spec
make lint      # ameba src spec
make test      # crystal spec
make clean     # Clean build artifacts
```

### Porting Workflow
1. Review upstream source in `vendor/chiasmus/`
2. Check `plans/inventory/` for existing parity tracking
3. Use `cross-language-crystal-parity` skill to bootstrap/validate parity plan
4. Implement against inventory items using `porting-to-crystal` workflow

### Language Mapping (TypeScript → Crystal)
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

## ✨ Features

### Formal Verification
- **Z3 SMT solver integration** - Mathematical proof of program properties
- **SWI-Prolog integration** - Logic programming and rule-based reasoning
- **Template-based problem formalization** - Natural language to formal logic translation

### Code Analysis
- **Tree-sitter parsing** - Multi-language source code analysis (Crystal, Python, Go, Clojure, JavaScript/TypeScript)
- **Call graph analysis** - Reachability, dead code detection, impact analysis
- **Fact extraction** - AST traversal to build knowledge graphs

### LLM Integration
- **MCP server** - Model Context Protocol for LLM tool access
- **Crig agent** - Multi-provider LLM support (DeepSeek, OpenAI, etc.)
- **Interactive REPL** - Agent-driven problem solving loop

### Example Use Cases
- **"Can our RBAC rules ever conflict?"** → Z3 finds the exact role/action/resource triple where allow and deny both fire
- **"Find compatible package versions"** → Z3 solves dependency constraints with incompatibility rules
- **"Can user input reach the database?"** → Prolog traces all paths through the call graph
- **"Are our frontend and backend validations consistent?"** → Z3 finds concrete inputs that pass one but fail the other
- **"What's the dead code in this module?"** → tree-sitter parses source files, Prolog finds unreachable functions
- **"What breaks if I change this function?"** → call graph impact analysis shows all transitive callers

## 📁 Project Structure

```
chiasmus.cr/
├── src/chiasmus/           # Main source code
│   ├── graph/             # Tree-sitter analysis (parsers, extractors, walkers)
│   ├── solvers/           # Z3, Prolog, and hybrid solvers
│   ├── mcp_server/        # MCP server implementation and tools
│   ├── llm/               # Crig integration and LLM drivers
│   └── rig_tool.cr        # Crig agent implementation
├── spec/                  # Crystal specs (test parity)
├── docs/                  # Technical documentation
├── plans/inventory/       # Porting inventory and parity tracking
├── vendor/               # Upstream source and dependencies
│   └── chiasmus/         # TypeScript upstream (git submodule)
└── lib_issues/           # Shard patch tracking
```

## 🔄 Porting Status

Active Crystal port with comprehensive parity tracking:

- **✅ Core architecture** - MCP server, solvers, graph analysis
- **✅ Tree-sitter integration** - Multi-language walkers with Crystal support
- **✅ Crolog integration** - SWI-Prolog bindings (patched)
- **✅ Crig integration** - LLM agent with DeepSeek support
- **🔄 Test coverage** - 57 examples, 0 failures
- **📋 Inventory tracking** - Complete API/test parity manifests

See `plans/inventory/` for detailed porting status and `AGENTS.md` for porting workflow.

## 🤝 Contributing

We welcome contributions! Please follow the porting workflow in `AGENTS.md`.

1. Fork the repository
2. Create your feature branch (`git checkout -b feat/amazing-feature`)
3. Commit your changes (`git commit -m 'feat: Add amazing feature'`)
4. Push to the branch (`git push origin feat/amazing-feature`)
5. Open a Pull Request

### Porting Guidelines
- **Upstream behavior is source of truth** - Port behavior first, then Crystal idioms
- **Inventory-first** - Track all work in `plans/inventory/` manifests
- **Test parity** - Port upstream tests as Crystal specs
- **Quality gates** - Run `make format`, `make lint`, `make test` before committing

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- **[yogthos/chiasmus](https://github.com/yogthos/chiasmus)** - Original TypeScript implementation
- **[Crystal community](https://crystal-lang.org/)** - For the amazing language and ecosystem
- **[All contributors](https://github.com/dsisnero/chiasmus.cr/graphs/contributors)** - Who help make this project better

## 📞 Support

- **Issues**: [GitHub Issues](https://github.com/dsisnero/chiasmus.cr/issues)
- **Documentation**: [docs/](docs/) directory
- **Agent guidance**: [AGENTS.md](AGENTS.md) for engineering workflows

---

**Chiasmus.cr** - Formal verification meets Crystal elegance. 🎯
