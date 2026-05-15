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

### Adding a New Language

This project supports tree-sitter-based code discovery for 19 programming languages.
Adding support for a new language requires several steps across different layers.

#### 1. Add the grammar submodule

```bash
git submodule add https://github.com/tree-sitter/tree-sitter-{LANG}.git \
  vendor/grammars/tree-sitter-{LANG}
```

For community grammars not in the `tree-sitter` GitHub org, use the full repo path:
```bash
git submodule add https://github.com/{owner}/tree-sitter-{lang}.git \
  vendor/grammars/tree-sitter-{lang}
```

#### 2. Compile the grammar

The project uses `tree-sitter-cli` to compile grammars into platform-specific shared libraries.
Compiled libraries are **not committed** to git (`.dylib`/`.so`/`.dll` are platform-specific).

**Quick compile (development):**
```bash
crystal run scripts/compile_new_grammars.cr
# Or for all grammars (CI/release):
crystal run scripts/setup_grammars.cr
```

**Manual compilation (for debugging):**
```bash
cd vendor/grammars/tree-sitter-{lang}
tree-sitter generate
tree-sitter build
# Output: libtree-sitter-{lang}.dylib (macOS) or .so (Linux)
```

Special cases handled by `compile_new_grammars.cr`:
- **tree-sitter-cpp**: depends on `tree-sitter-c/grammar.js` as an npm module.
  The script copies it from the vendored c grammar.
- **tree-sitter-php**: `grammar.js` is in a `php/` subdirectory.
  Compile from `php/` not the repo root.
- **tree-sitter-proto**: Uses ABI 14 (pre-ABI 15, no `tree-sitter.json`).
  The `tree-sitter` CLI generates with a warning but succeeds.

#### 3. Create a language extractor

Create `src/chiasmus/discovery/extractors/{lang}_extractor.cr`:

```crystal
require "../extractor"

module Chiasmus
  module Discovery
    struct MyLangExtractor < QueryExtractor
      def language : String
        "mylang"
      end

      def extensions : Array(String)
        [".ext"]
      end

      def grammar_language : String
        "mylang"  # must match the grammar's tree-sitter language name
      end

      def queries : Hash(String, String)
        {
          "class"    => "(class_declaration name: (identifier) @name) @def",
          "function" => "(function_declaration name: (identifier) @name) @def",
        }
      end

      # Optional: add codeium-parse-style enriched queries with custom predicates
      def predicate_queries : Hash(String, String)
        {
          "definition.import" => "(import_statement source: (string) @name)",
        }
      end

      # Optional: filter/transform matched names
      def post_filter(kind : String, name : String, node : TreeSitter::Node?, source : String) : String?
        name
      end
    end
  end
end
```

Key points:
- `grammar_language` must match the name used by `tree-sitter` CLI (check `tree-sitter.json` or `grammar.js`).
- Use `queries` for simple single-capture patterns with `@name` and `@def`.
- Use `predicate_queries` for patterns with multiple captures (`@doc`, `@codeium.parameters`, `@parent`, etc.) or custom predicates.
- The extractor is auto-discovered via `require "./discovery/extractors/*"` in `discovery.cr`.

#### 4. Update the LanguageRegistry (optional)

If you need the language registered in the grammar CLI or graph subsystem, add an entry to
`src/chiasmus/graph/language_registry.cr`:

```crystal
registry["mylang"] = LanguageInfo.new(
  name: "mylang",
  package: "tree-sitter-mylang",
  extensions: [".ext"]
)
```

#### 5. Add golden reference data

Create a golden output spec entry in `spec/chiasmus/discovery/codeium_parse_golden_spec.cr`
(or generate via the golden shard):

```crystal
describe "Codeium-parse golden: mylang" do
  it "matches golden output" do
    result = extract_for("mylang", "ext")
    pending "mylang grammar not available" unless result
    tree = result.not_nil![0]
    source = result.not_nil![1]
    ext = result.not_nil![2]
    output = items_output(Chiasmus::Discovery::MyLangExtractor.new, tree, source, ext)
    Golden.require_equal("test_mylang", output, test_data_dir: GOLDEN_DIR)
  end
end
```

Generate the initial golden file:
```bash
GOLDEN_UPDATE=1 crystal spec spec/chiasmus/discovery/codeium_parse_golden_spec.cr
```

#### Current grammar inventory

| Language | Grammar submodule | Status |
|----------|------------------|--------|
| crystal | `vendor/grammars/tree-sitter-crystal` | ✓ compiled |
| go | `vendor/grammars/tree-sitter-go` | ✓ compiled |
| java | `vendor/grammars/tree-sitter-java` | ✓ compiled |
| javascript | `vendor/grammars/tree-sitter-javascript` | ✓ compiled |
| python | `vendor/grammars/tree-sitter-python` | ✓ compiled |
| ruby | `vendor/grammars/tree-sitter-ruby` | ✓ compiled |
| rust | `vendor/grammars/tree-sitter-rust` | ✓ compiled |
| scala | `vendor/grammars/tree-sitter-scala` | ✓ compiled |
| typescript/tsx | `vendor/grammars/tree-sitter-typescript` | ✓ compiled |
| bash | `vendor/grammars/tree-sitter-bash` | ✓ compiled |
| c | `vendor/grammars/tree-sitter-c` | ✓ compiled |
| cpp | `vendor/grammars/tree-sitter-cpp` | ✓ compiled |
| csharp | `vendor/grammars/tree-sitter-c-sharp` | ⚠ dylib pending |
| dart | `vendor/grammars/tree-sitter-dart` | ✓ compiled |
| kotlin | `vendor/grammars/tree-sitter-kotlin` | ✓ compiled |
| perl | `vendor/grammars/tree-sitter-perl` | ✓ compiled |
| php | `vendor/grammars/tree-sitter-php` | ✓ compiled |
| protobuf | `vendor/grammars/tree-sitter-proto` | ✓ compiled |

## Contributing

See the [Contributing section](../README.md#-contributing) in README.md for guidelines.