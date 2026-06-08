# Adding a New Language to Chiasmus

This guide walks through adding full tree-sitter graph extraction support for a new language, using **C#** as the concrete example. The same pattern applies to any language with a [tree-sitter grammar](https://tree-sitter.github.io/tree-sitter/).

## Overview

Adding a new language requires four layers:

| Layer | What | File(s) |
|-------|------|---------|
| Grammar | Compiled tree-sitter shared library | `vendor/grammars/tree-sitter-{lang}/` |
| Walker | AST walking → CodeGraph facts | `src/chiasmus/graph/walkers/{lang}.cr` |
| Extractor | Wired into extract pipeline | `src/chiasmus/graph/extractor.cr` |
| Spec | Red-green TDD verification | `spec/chiasmus/graph/{lang}_walker_spec.cr` |

Optionally add a discovery extractor for codeium-parse symbol scanning:

| Layer | What | File(s) |
|-------|------|---------|
| Discovery Extractor | Symbol-level scanning via tree-sitter queries | `src/chiasmus/discovery/extractors/{lang}_extractor.cr` |

---

## Step 1: Find and Clone the Tree-Sitter Grammar

Tree-sitter grammars follow the naming convention `tree-sitter-{language}` on GitHub.

```bash
# List existing grammars
ls vendor/grammars/

# Clone the grammar as a git submodule
git submodule add https://github.com/tree-sitter/tree-sitter-c-sharp.git \
  vendor/grammars/tree-sitter-c-sharp
```

Check if the grammar already exists in the vendor directory — many are pre-vendored.

### Grammar Naming Edge Cases

Some languages have non-obvious naming. For example:

| Language | Package name | Symbol name | Notes |
|----------|-------------|-------------|-------|
| csharp | `tree-sitter-c-sharp` | `tree_sitter_c_sharp` | Hyphen in repo name, underscore in symbol |

The symbol name can be found by inspecting the grammar's `parser.c` or `grammar.js` for the `tree_sitter_*` function, or by checking a compiled library:

```bash
nm vendor/grammars/tree-sitter-c-sharp/libtree-sitter-csharp.dylib | grep tree_sitter
# Output: T _tree_sitter_c_sharp
```

### Registry Check

Verify the language is registered in `src/chiasmus/graph/language_registry.cr`:

```crystal
# csharp was already registered
registry["csharp"] = LanguageInfo.new(
  name: "csharp",
  package: "tree-sitter-c-sharp",
  extensions: [".cs"]
)
```

If your language is missing, add it following the same pattern.

---

## Step 2: Build the Grammar Binary

Compile the grammar into a shared library. Use the grammar CLI tool:

```bash
# Build via chiasmus-grammar CLI
bin/chiasmus-grammar compile csharp

# Or manually via tree-sitter CLI
cd vendor/grammars/tree-sitter-c-sharp
tree-sitter generate
tree-sitter build
```

Verify the output:

```bash
file vendor/grammars/tree-sitter-c-sharp/libtree-sitter-csharp.dylib
# Mach-O 64-bit dynamically linked shared library arm64
```

### Grammar Loader Handing

If the grammar has a symbol name different from the language name (like `csharp` → `tree_sitter_c_sharp`), handle it in `src/chiasmus/graph/language_loader.cr`:

```crystal
def load_language_from_grammar_path(language : String, grammar_path : String?) : TreeSitter::Language?
  # csharp: symbol is tree_sitter_c_sharp, file is libtree-sitter-csharp
  if language == "csharp"
    ts_name = "c_sharp"
    repo_root = Path[__DIR__].join("../../..").expand
    vendor_path = repo_root.join("vendor/grammars/tree-sitter-c-sharp").to_s
    vendor_dir = Path.new(vendor_path)
    if Dir.exists?(vendor_path)
      ts_language = load_dylib(ts_name, vendor_dir)
      return TreeSitter::Language.new(language, ts_language)
    end
  end
  # ... standard loading path
end
```

Only add special handling when the symbol name differs from the language name. Most languages use the same name (e.g., `tree_sitter_python`, `tree_sitter_go`, `tree_sitter_rust`).

---

## Step 3: Study the Tree-Sitter Grammar Nodes

Before writing the walker, understand what AST node types the grammar produces. Write a small test file and inspect the parse tree:

```crystal
require "./src/chiasmus/graph/parser"
include Chiasmus::Graph

code = <<-CS
  public class Service {
    public void Handle(string input) {
      var result = Helper.Process(input);
    }
  }
CS

tree = Parser.parse_source(code, "/tmp/test.cs")
puts tree.root_node.sexp(code)
```

Key node types for C#:

| AST Node | SymbolKind | Notes |
|----------|-----------|-------|
| `class_declaration` | Class | Also `struct_declaration` |
| `interface_declaration` | Interface | |
| `enum_declaration` | Type | |
| `method_declaration` | Method | |
| `constructor_declaration` | Method | Name is the class name; map to `.ctor` |
| `invocation_expression` | — | Call edge source |
| `member_access_expression` | — | `obj.Method()` calls |
| `using_directive` | — | Namespace import |
| `namespace_declaration` | — | Scope container |

---

## Step 4: Write the Walker (RED-GREEN TDD)

Create `src/chiasmus/graph/walkers/csharp.cr` with this structure:

```crystal
require "../types"

module Chiasmus
  module Graph
    module Walkers
      def walk_csharp(
        node : TreeSitter::Node,
        source : String,
        file_path : String,
        scope_stack : Array(String),
        defines : Array(DefinesFact),
        calls : Array(CallsFact),
        imports : Array(ImportsFact),
        exports : Array(ExportsFact),
        contains : Array(ContainsFact),
        call_set : Set(String),
      ) : Nil
        # 1. Handle declarations (class, method, etc.) — returns true if handled
        return if handle_csharp_declaration(node, source, file_path, scope_stack,
          defines, calls, imports, contains, call_set)

        # 2. Handle call expressions
        handle_csharp_call(node, source, scope_stack, calls, call_set)

        # 3. Handle imports (using directives)
        handle_csharp_using(node, source, file_path, imports)

        # 4. Recurse into children
        walk_csharp_children(node, source, file_path, scope_stack,
          defines, calls, imports, exports, contains, call_set)
      end
    end
  end
end
```

### Step 4a: Write RED Specs First

Create `spec/chiasmus/graph/csharp_walker_spec.cr`:

```crystal
require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/walkers"
require "../../../src/chiasmus/graph/extractor"

include Chiasmus::Graph

describe "C# graph walker" do
  it "extracts class declarations from C# source" do
    cs = <<-CS
      public class Service {
        public void Handle() {}
      }
    CS
    sources = [SourceFile.new(path: "/tmp/test.cs", content: cs)]
    graph = Extractor.extract_graph(sources)
    graph.defines.size.should be >= 2  # Service + Handle
    names = graph.defines.map(&.name).to_set
    names.should contain("Service")
    names.should contain("Handle")
  end

  it "captures method calls between classes" do
    cs = <<-CS
      public class Caller {
        public void Run() {
          var svc = new Service();
          svc.Handle();
        }
      }
      public class Service {
        public void Handle() {}
      }
    CS
    sources = [SourceFile.new(path: "/tmp/test5.cs", content: cs)]
    graph = Extractor.extract_graph(sources)
    callees = graph.calls.map(&.callee).to_set
    callees.should contain("Handle")
  end

  it "captures using directives as imports" do
    cs = <<-CS
      using System;
      using System.Collections.Generic;
      public class Foo {}
    CS
    sources = [SourceFile.new(path: "/tmp/test6.cs", content: cs)]
    graph = Extractor.extract_graph(sources)
    graph.imports.size.should be >= 1
    import_names = graph.imports.map(&.name).to_set
    import_names.should contain("System")
  end
end
```

Run it RED:

```bash
crystal spec spec/chiasmus/graph/csharp_walker_spec.cr -v
# Expected: failures because walker doesn't exist yet
```

### Step 4b: Wire Into extractor.cr

Add the language case to `extract_with_walkers` in `src/chiasmus/graph/extractor.cr`:

```crystal
when "csharp"
  Walkers.walk_csharp(tree.root_node, file.content, file.path,
    scope_stack, defines, calls, imports, exports, contains, call_set)
```

### Step 4c: Register the Walker

Add the require to `src/chiasmus/graph/walkers.cr`:

```crystal
require "./walkers/csharp"
```

### Step 4d: Implement Declaration Handlers

Extract complex switch cases into focused methods to keep cyclomatic complexity low:

```crystal
private def handle_csharp_class(node, source, file_path, scope_stack,
    defines, calls, imports, contains, call_set)
  name = node.child_by_field_name("name").try(&.text(source))
  return false unless name
  defines << DefinesFact.new(file: file_path, name: name,
    kind: SymbolKind::Class, line: node.start_point.row.to_i + 1)
  with_scope(scope_stack, name) do
    walk_csharp_children(node, source, file_path, scope_stack,
      defines, calls, imports, [] of ExportsFact, contains, call_set)
  end
  true
end
```

### Step 4e: Handle Call Resolution

Extract method names from `invocation_expression` nodes, handling both direct calls and member-access expressions:

```crystal
private def resolve_csharp_callee(call_node : TreeSitter::Node, source : String) : String?
  func_node = call_node.child_by_field_name("function")
  if func_node
    # obj.Method() → extract "Method" from member_access_expression
    if func_node.type == "member_access_expression"
      name = func_node.child_by_field_name("name")
      return name.text(source) if name
    end
    return func_node.text(source)
  end
  nil
end
```

### Step 4f: Run GREEN

```bash
crystal spec spec/chiasmus/graph/csharp_walker_spec.cr -v
# Expected: all pass
```

---

## Step 5: Verify Against Real Codebases

Test the walker on a real codebase to catch edge cases:

```crystal
require "./src/chiasmus/mcp_server/tools/graph"
require "./src/chiasmus/mcp_server/tools/map"

# chiasmus_map overview
tool = Chiasmus::MCPServer::Tools::MapTool.new
files = Dir.glob("/path/to/csharp/project/src/**/*.cs").first(40)
r = tool.invoke({
  "files"  => JSON::Any.new(files.map { |f| JSON::Any.new(f) }),
  "mode"   => JSON::Any.new("overview"),
  "format" => JSON::Any.new("markdown"),
})
puts r.as(Chiasmus::MCPServer::Types::MapResponse).content
```

Tested on [Kiota](https://github.com/microsoft/kiota) (1,288 C# files):
```
Files: 40 | Definitions: 200 | Exports: 0
Functions: 103 | Classes: 26 | Call Edges: 367 | Imports: 63
```

---

## Step 6: Code Gates

Run the full quality pipeline before committing:

```bash
# Format
crystal tool format src spec

# Lint (zero failures required)
ameba src spec

# Tests (zero failures required)
crystal spec
```

Update `plans/parity.md` with the new feature entry, then commit.

---

## Quick Reference: Files to Touch

| File | What to do |
|------|-----------|
| `vendor/grammars/tree-sitter-{lang}/` | Clone grammar submodule, build shared library |
| `src/chiasmus/graph/language_registry.cr` | Add language if not registered |
| `src/chiasmus/graph/language_loader.cr` | Add symbol name mapping if needed (rare) |
| `src/chiasmus/graph/walkers/{lang}.cr` | **Create** — the AST walker |
| `src/chiasmus/graph/walkers.cr` | Add `require` line |
| `src/chiasmus/graph/extractor.cr` | Add `when "lang"` case |
| `spec/chiasmus/graph/{lang}_walker_spec.cr` | **Create** — red-green TDD specs |
| `plans/parity.md` | Add feature entry |

## Common Patterns

### Scope Tracking

Use `with_scope` for nodes that introduce a scope (classes, namespaces, methods). Call edges attach to the current scope via `scope_stack.last?`:

```crystal
with_scope(scope_stack, class_name) do
  walk_csharp_children(node, ...)
end
```

### Constructor Names

Constructors have the class name in tree-sitter. Map to `.ctor` to avoid collision with the class definition:

```crystal
when "constructor_declaration"
  defines << DefinesFact.new(name: ".ctor", kind: SymbolKind::Method, ...)
```

### Namespace Handling

Namespaces are scope containers — they don't produce DefinesFact entries but their children are scoped under them:

```crystal
when "namespace_declaration"
  with_scope(scope_stack, namespace_name) do
    walk_csharp_children(node, ...)
  end
  true
```

### Grammar Symbol Naming Edge Cases

If `nm vendor/grammars/tree-sitter-{lang}/libtree-sitter-{lang}.dylib` shows a symbol name different from the language name, add mapping in `language_loader.cr`. Most languages don't need this.
