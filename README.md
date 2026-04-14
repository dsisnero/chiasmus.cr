# Chiasmus

This repository is a Crystal port of https://github.com/yogthos/chiasmus.

**Upstream source pinned at:** `vendor/chiasmus` (git submodule tracking `main` branch)

Chiasmus is an MCP server that gives LLMs access to formal verification via Z3 (SMT solver) and Tau Prolog, plus tree-sitter-based source code analysis. Translates natural language problems into formal logic using a template-based pipeline, verifies results with mathematical certainty, and analyzes call graphs for reachability, dead code, and impact analysis.

## Installation

```bash
shards install
```

## Usage

TODO: Write Crystal-specific usage instructions here

## Development

```bash
make install    # Install dependencies
make format     # Format code
make lint       # Run linters
make test       # Run tests
make clean      # Clean build artifacts
```

## Upstream README Highlights

### Example use cases

- **"Can our RBAC rules ever conflict?"** → Z3 finds the exact role/action/resource triple where allow and deny both fire
- **"Find compatible package versions"** → Z3 solves dependency constraints with incompatibility rules, returns a valid assignment or proves none exists
- **"Can user input reach the database?"** → Prolog traces all paths through the call graph, flags taint flows to sensitive sinks
- **"Are our frontend and backend validations consistent?"** → Z3 finds concrete inputs that pass one but fail the other (e.g. age=15 passes frontend min=13 but fails backend min=18)
- **"Does our workflow have dead-end or unreachable states?"** → Prolog checks reachability from the initial state, identifies orphaned and terminal nodes
- **"What's the dead code in this module?"** → tree-sitter parses source files, Prolog finds functions unreachable from any entry point
- **"What breaks if I change this function?"** → call graph impact analysis shows all transitive callers

### Key Features

- MCP server for formal verification
- Z3 SMT solver integration
- Tau Prolog integration
- Tree-sitter-based source code analysis
- Template-based problem formalization
- Call graph analysis (reachability, dead code, impact analysis)

For full documentation, see the [upstream README](vendor/chiasmus/README.md).

## Porting Status

This is an active Crystal port. See `AGENTS.md` for porting workflow and `plans/inventory/` for parity tracking.

## Contributing

1. Fork it (<https://github.com/dsisnero/code_rule/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Dominic Sisneros](https://github.com/dsisnero) - creator and maintainer
