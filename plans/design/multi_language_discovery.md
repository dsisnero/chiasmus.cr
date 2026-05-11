# P3.1 / P3.2: Multi-Language Tree-Sitter Discovery Design

## Architecture Overview

```
                         Discovery::Pipeline (non-blocking)
                                  │
                    ┌─────────────┼─────────────┐
                    │             │             │
              Fiber worker   Fiber worker   Fiber worker
                    │             │             │
              ┌─────┴─────┐ ┌─────┴─────┐ ┌─────┴─────┐
              │  Parser   │ │  Parser   │ │  Parser   │
              │  Extract  │ │  Extract  │ │  Extract  │
              └───────────┘ └───────────┘ └───────────┘
                    │             │             │
                    └─────────────┼─────────────┘
                                  │
                           Channel(Item)
                                  │
                          Result collector
                                  │
                           Array(Item) + parser_mode
```

## SOLID Design

### S — Single Responsibility

| Class | Responsibility |
|-------|---------------|
| `LanguageExtractor` (abstract) | Define extraction interface |
| `QueryExtractor` (base) | Tree-sitter query execution, result collection |
| `TypeScriptExtractor`, `PythonExtractor`, etc. | Language-specific query patterns |
| `ExtractorRegistry` | Map file extensions → extractors |
| `Pipeline` | Concurrent file processing, result aggregation |
| `GrammarLoader` | Platform-aware grammar loading (moved from Discovery) |

### O — Open/Closed

New languages added by subclassing `QueryExtractor` and registering in `ExtractorRegistry`. Pipeline, loader, and CLI are untouched.

### L — Liskov Substitution

All extractors implement `extract(root_node, source, file_path) : Array(Item)`. Pipeline depends on the abstraction, not concretions.

### I — Interface Segregation

- `LanguageExtractor` — minimal interface: `language`, `extensions`, `grammar_language`, `extract`
- `QueryExtractor` (mixin concern) — adds `run_query`, `extract_with_queries`
- `WalkerExtractor` (future) — for languages needing tree-walking beyond queries

### D — Dependency Inversion

```crystal
abstract struct LanguageExtractor
  abstract def language : String
  abstract def extensions : Array(String)
  abstract def grammar_language : String
  abstract def extract(root_node : TreeSitter::Node, source : String, file_path : String) : Array(Item)
end
```

Pipeline accepts `Array(LanguageExtractor)`, not concrete types.

## Concurrency Model (Non-Blocking)

```crystal
class Pipeline
  # Process files concurrently using Crystal fibers + channels
  def discover(source_dir : String, extractors : Array(LanguageExtractor)) : Result
    registry = ExtractorRegistry.new(extractors)

    # Find matching files
    files = scan_files(source_dir, registry)

    # Bounded parallelism: max concurrent parses
    max_concurrent = System.cpu_count
    semaphore = Channel(Nil).new(max_concurrent)
    results = Channel(Array(Item)).new(files.size)

    files.each do |file_path, content|
      spawn do
        semaphore.send(nil)  # Acquire slot
        begin
          extractor = registry.for_file(file_path)
          next unless extractor

          lang = Discovery.load_language(extractor.grammar_language)
          next unless lang

          parser = TreeSitter::Parser.new(language: lang)
          tree = parser.parse(nil, content)
          items = extractor.extract(tree.root_node, content, file_path)
          results.send(items)
        rescue ex
          # Log and continue
        ensure
          semaphore.receive  # Release slot
        end
      end
    end

    # Collect results (non-blocking with timeout)
    all_items = [] of Item
    files.size.times do
      select
      when items = results.receive
        all_items.concat(items)
      when timeout(30.seconds)
        break
      end
    end

    Result.new(items: deduplicate(all_items), parser_mode: "tree-sitter")
  end
end
```

## Language Extractor Matrix

| Language | Grammar | Class | Interface | Function | Method | Constant | Test |
|----------|---------|-------|-----------|----------|--------|----------|------|
| typescript | tree-sitter-typescript | `class_declaration` `abstract_class_declaration` | `interface_declaration` | `function_declaration` arrow `variable_declarator` | `method_definition` + enclosing class | `lexical_declaration` UPPERCASE | `describe`/`it`/`test` |
| javascript | tree-sitter-javascript | `class_declaration` | — | `function_declaration` arrow `variable_declarator` | `method_definition` | UPPERCASE `lexical_declaration` | `describe`/`it`/`test` |
| tsx | tree-sitter-typescript (tsx) | same as typescript | same | same | same | same | same |
| python | tree-sitter-python | `class_definition` | — | `function_definition` (non-class) | `function_definition` (in class) | UPPERCASE `assignment` | `test_*` functions |
| go | tree-sitter-go | `type_spec`→`struct_type` | `type_spec`→`interface_type` | `function_declaration` | `method_declaration` | `const_spec` | `TestXxx` functions |
| java | tree-sitter-java | `class_declaration` `enum_declaration` `record_declaration` | `interface_declaration` | `method_declaration` (top) | `method_declaration` (in class) | `static final` UPPERCASE | `@Test` annotated |
| rust | tree-sitter-rust | `struct_item` `enum_item` `impl_item` | `trait_item` | `function_item` | `function_item` (in impl) | `const_item` | `#[test]` annotated |
| ruby | tree-sitter-ruby | `class` | `module` | — | `method` `singleton_method` | UPPERCASE `constant` | `test_*` methods |
| crystal | tree-sitter-crystal | `class_def` `struct_def` | `module_def` | — | `method_def` | `(constant)` node type | `describe`/`it` blocks |
| scala | tree-sitter-scala | `class_definition` `object_definition` | `trait_definition` | `function_definition` | `function_definition` (in class) | UPPERCASE `val` | specs |

## Query Pattern Design

Each extractor defines query patterns as S-expression strings keyed by target kind:

```crystal
class TypeScriptExtractor < QueryExtractor
  def queries : Hash(String, String)
    {
      "class"     => "(class_declaration name: (type_identifier) @name) @def\n(abstract_class_declaration name: (type_identifier) @name) @def",
      "interface" => "(interface_declaration name: (type_identifier) @name) @def",
      "function"  => "(function_declaration name: (identifier) @name) @def\n(variable_declarator name: (identifier) @name value: (arrow_function) @def)",
      "method"    => "(method_definition name: (property_identifier) @name) @def",
      "const"     => "(lexical_declaration (variable_declarator name: (identifier) @name) @def)",
      "test"      => "(expression_statement (call_expression function: (identifier) @test_func arguments: (arguments (string (string_fragment) @test_name))) @def)",
    }
  end

  def post_filter(kind : String, name : String, node : TreeSitter::Node, source : String) : String?
    case kind
    when "const" then name =~ /^[A-Z][A-Z0-9_]*$/ ? name : nil
    when "method" then qualify_with_enclosing_class(node, source, name)
    when "test" then validate_test_func(node, source, name)
    else name
    end
  end
end
```

## P3.1 vs P3.2 Scope

### P3.1 — Core Abstractions + Python, Go, Java, Rust
- `LanguageExtractor` abstract
- `QueryExtractor` base
- `ExtractorRegistry`
- `Pipeline` with concurrency
- `GrammarLoader` (refactored from Discovery)
- Extractors: TypeScript (existing), Python, Go, Java, Rust

### P3.2 — Remaining Languages + CLI Integration
- Extractors: JavaScript, TSX, Ruby, Crystal, Scala
- CLI integration (chiasmus-discover supports all languages)
- Ruby parity script integration for all languages
- Comprehensive specs for all extractors

## File Layout

```
src/chiasmus/discovery/
  extractor.cr            # LanguageExtractor abstract + QueryExtractor base
  registry.cr             # ExtractorRegistry (ext→extractor mapping)
  pipeline.cr             # Pipeline (non-blocking concurrent discovery)
  grammar_loader.cr       # Platform-aware grammar loading (from discovery.cr)
  extractors/
    typescript_extractor.cr  # TypeScript/TSX
    javascript_extractor.cr  # JavaScript
    python_extractor.cr      # Python
    go_extractor.cr          # Go
    java_extractor.cr        # Java
    rust_extractor.cr        # Rust
    ruby_extractor.cr        # Ruby
    crystal_extractor.cr     # Crystal
    scala_extractor.cr       # Scala

spec/chiasmus/discovery/
  extractor_spec.cr
  registry_spec.cr
  pipeline_spec.cr
  grammar_loader_spec.cr
  extractors/
    typescript_extractor_spec.cr
    python_extractor_spec.cr
    go_extractor_spec.cr
    java_extractor_spec.cr
    rust_extractor_spec.cr
    ruby_extractor_spec.cr
    crystal_extractor_spec.cr
    scala_extractor_spec.cr
```

## Acceptance Criteria

1. `chiasmus-discover --language python --dir vendor/` returns Python declarations
2. All 10 languages have TDD specs with at least class, function, and constant coverage
3. Pipeline processes 100+ files concurrently without blocking
4. Pipeline shows parser_mode="tree-sitter" in output for languages with grammars
5. Falls back to regex gracefully with parser_mode="regex" when grammar unavailable
6. Regex fallback works for all 10 languages
7. Quality gates pass: `crystal tool format`, `ameba`, `crystal spec`

## Automation Scripts

Two scripts support grammar exploration and AST debugging:

### `scripts/explore_grammar_nodes.cr`
Reads `node-types.json` from a grammar directory and generates:
- Summary of definition nodes and field names
- Suggested tree-sitter query patterns

```bash
crystal run scripts/explore_grammar_nodes.cr -- \
  --grammar vendor/grammars/tree-sitter-python --queries
```

### `scripts/explore_ast.cr`
Parses source code with tree-sitter and prints:
- Full AST tree (with field names and depth control)
- Unique node type list (`--node-types`)
- Node + field name mapping (`--fields`)

```bash
crystal run scripts/explore_ast.cr -- \
  --grammar vendor/grammars/tree-sitter-python \
  --source "class Foo: pass"
```
