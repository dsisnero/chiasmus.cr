# Development Guide

## Setup

### Prerequisites
1. **Crystal** (>= 1.19.1): https://crystal-lang.org/install/
2. **SWI-Prolog**: Required for Prolog solver integration
   - macOS: `brew install swi-prolog`
   - Ubuntu: `sudo apt-get install swi-prolog`
3. **Z3**: Optional but recommended for SMT solving
   - macOS: `brew install z3`
   - Ubuntu: `sudo apt-get install z3`

### Repository Setup
```bash
# Clone with submodules
git clone --recursive https://github.com/dsisnero/chiasmus.cr.git
cd chiasmus.cr

# Install Crystal dependencies
shards install

# Verify installation
make test
```

## Workflow

### Code Quality

```bash
make format    # Format code
make lint      # Run linters
make test      # Run tests
```

### Porting Workflow

1. **Inventory First**: All porting work must be tracked in `plans/inventory/` manifests
2. **Behavior Faithfulness**: Upstream behavior is the source of truth - port behavior first, then Crystal idioms
3. **Test Parity**: Port upstream tests as Crystal specs early in the process
4. **Continuous Verification**: Run quality gates (`make format`, `make lint`, `make test`) frequently
5. **Shard Patching**: Use `crystal-shard-lib-patch` skill when modifying `lib/` dependencies

### Using Skills for Porting

| Task | Skill |
|------|-------|
| General porting workflow | `porting-to-crystal` |
| Source API/test inventory, drift checks | `cross-language-crystal-parity` |
| Crystal shard selection/replacement | `find-crystal-shards` |
| Local edits under `./lib` shard sources | `crystal-shard-lib-patch` |

### Testing Strategy

- Port upstream tests as Crystal specs
- Preserve test logic and assertions exactly
- Add characterization specs for untested behavior
- Maintain fixture parity with upstream

## Debugging

### Common Issues

#### Language Mapping (TypeScript → Crystal)
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
| `Map<K, V>` | `Hash(K, V)` |
| `Array<T>` | `Array(T)` |
| `Set<T>` | `Set(T)` |
| `number` | `Int32`/`Int64`/`Float64` (preserve signedness/range) |
| `Buffer` | `Bytes` (`Slice(UInt8)`) |

#### Concurrency Patterns
- Use `spawn` for non-blocking operations (LLM calls, Prolog queries)
- Use `Channel` for communication between fibers
- Preserve Go/Crystal concurrency patterns for MCP server responsiveness
- Ensure all external calls (LLM, Prolog, Z3) use non-blocking patterns

### Development Tools

#### Quality Gates
```bash
make format    # crystal tool format --check src spec
make lint      # ameba src spec
make test      # crystal spec
```

#### Debugging
- `crystal spec --verbose` - Detailed test output
- `crystal tool context` - Show compilation context
- `ameba --only Lint/UnusedArgument` - Focus on specific lint rules
- `crystal build src/chiasmus.cr -o /tmp/debug` - Build for debugging

#### Tree-sitter Development
- Grammar files in `vendor/grammars/`
- Built parsers in `src/tree_sitter/`
- Use `tree-sitter build` to rebuild grammars
- Test with `crystal spec spec/chiasmus/graph/crystal_walker_spec.cr`

## Contributing

See the [Contributing section](../README.md#-contributing) in README.md for guidelines.