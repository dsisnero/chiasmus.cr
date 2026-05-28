# Code Index Plan

## Problem

The `chiasmus_search` MCP tool can only search 7 of 18 languages with Discovery extractors. The search engine consumes the Graph pipeline (`CodeGraph` → `DefinesFact`), which requires a dedicated tree-sitter walker per language. The Discovery pipeline has 18 extractors producing `Discovery::Item` records with rich symbol capture (class, interface, type, function, method, const, test, field, etc.), but there's no bridge from Discovery to search.

Additionally, the current search engine only indexes `Function`/`Method` kinds — classes, interfaces, type aliases, and constants are excluded. A multi-language code index should let each language configure which symbol kinds are indexable.

## Architecture

Bridge the Discovery pipeline directly to a searchable code index, bypassing the Graph pipeline entirely for semantic search. Use Crig's `InMemoryVectorStore(D)` with generic document types and builder patterns.

```
Source files → Discovery Pipeline (18 extractors)
                    │
                    ▼
            Discovery::Item[]  (class, function, method, interface, type, const, test, ...)
                    │
                    ▼
            CodeIndex::Builder   (per-language config, text preparation)
                    │
                    ▼
            Crig::InMemoryVectorStore(CodeDocument)
                    │
                    ▼
            Crig::InMemoryVectorIndex(M, CodeDocument)
                    │  (implements VectorStoreIndex + ToolDyn)
                    ▼
            Semantic search across all languages
```

### Key Design Decisions

1. **Generic document type** (`CodeDocument`) carries: id, name, kind, language, file, line, signature, leading_doc, snippet, full_text_for_embedding

2. **Builder pattern** (Crig-style fluent API): `CodeIndex.for_language("go").with_config(default_go_config).from_items(items, source_files).embed_with(model).build`

3. **Per-language configuration** (`CodeIndexConfig`): which symbol kinds to index, text preparation strategy, snippet extraction

4. **Crig `InMemoryVectorStore(CodeDocument)`** stores full documents alongside vectors — rich results without secondary lookup

5. **Crig `InMemoryVectorIndex(M, CodeDocument)`** exposes the index as a Crig tool (`Crig::ToolDyn`) for MCP registration

## Types

```crystal
# Which symbol kinds to index for a language
record CodeIndexConfig,
  indexed_kinds : Set(String),           # e.g. {"function", "method", "class"}
  max_text_len : Int32 = 2000,
  snippet_lines : Int32 = 6,
  normalize_name : Proc(String, String)?  # optional name transformation

# Rich document type stored alongside vectors
record CodeDocument,
  id : String,                    # "src/app.go#Server.ServeHTTP#42"
  name : String,                  # "Server.ServeHTTP" or "MyClass"
  kind : String,                  # "function", "class", "interface", ...
  language : String,              # "go", "typescript", ...
  file : String,                  # "src/app.go"
  line : Int32,                   # 1-based
  signature : String?,            # func (s *Server) ServeHTTP(w, r)
  leading_doc : String?,          # JSDoc / docstring / Go comment
  text : String                   # Full text for embedding
      # = [name] [signature] [leading_doc] [snippet]
      # capped at max_text_len

# Search result with full context
record CodeSearchHit,
  score : Float64,
  document : CodeDocument

# Fluent builder (Crig pattern)
class CodeIndex
  # Class methods
  def self.for_language(language : String) : Builder

  struct Builder
    def with_config(config : CodeIndexConfig) : Builder
    def from_items(items : Array(Discovery::Item), sources : Hash(String, String)) : Builder
    def embed_with(model : Crig::EmbeddingModelDyn) : Builder
    def build : CodeIndex
  end

  # Instance methods
  def search(query : String, top_k : Int32, model : Crig::EmbeddingModelDyn) : Array(CodeSearchHit)
  def search(filter_language : String?, filter_kind : String?, query : String, top_k : Int32, model) : Array(CodeSearchHit)
  def language : String
  def count : Int32
end
```

## Implementation Plan

### P9.1: CodeDocument + CodeIndexConfig

**Source**: `src/chiasmus/search/code_index.cr` (types + config)
**Spec**: `spec/chiasmus/search/code_index_spec.cr`

- `CodeDocument` record with JSON serialization
- `CodeIndexConfig` with sensible defaults
- Default configs per language (which kinds are "code symbols" worth indexing)
- Text preparation: `name + snippet`, capped at max_text_len

Tests:
1. `CodeDocument` round-trips through JSON
2. `CodeDocument` handles nil optional fields through JSON
3. `CodeIndexConfig` default indexed_kinds = function + method
4. `CodeIndexConfig` defaults max_text_len to 2000
5. `CodeIndexConfig` defaults snippet_lines to 6
6. `CodeIndexConfig` accepts custom indexed_kinds
7. `CodeIndexConfig#includes_kind?` filters correctly
8. Go defaults include class + interface
9. TypeScript defaults include class + interface + type
10. Unknown language falls back to function+method

**Status**: `[x]` Implemented (10 specs)

### P9.2: CodeIndex::Builder + CodeIndex class

- `CodeIndex::Builder` with fluent API matching Crig's `InMemoryVectorStoreBuilder`
- `from_items(items, sources)` converts `Discovery::Item[]` → `CodeDocument[]`
  - Filters by `config.indexed_kinds`
  - Extracts snippet from source content (snippet_lines around detected line)
  - Resolves line numbers by searching source for symbol name
- `build` → constructs `CodeIndex` holding documents
- `CodeIndex#count`, `CodeIndex#language`

Tests:
11. `for_language` returns Builder with correct language
12. Builder defaults config from language defaults
13. Builder accepts custom config via `with_config`
14. Builder filters items by indexed_kinds
15. Builder produces CodeDocuments with correct fields
16. Builder extracts snippet around symbol line
17. Builder handles missing source content gracefully
18. Builder rejects items with empty id
19. `build` returns a valid CodeIndex
20. Empty index `count` returns 0
21. `language` getter returns configured language

**Status**: `[x]` Implemented (11 specs)

### P9.3: CodeIndex#search

- `search(query, top_k)` keyword-in-text scoring
- `SearchResult` record with score + document
- Results sorted by descending score, truncated to top_k

Tests:
22. Empty index returns empty results
23. Keyword match finds correct document
24. top_k limits result count
25. Client-side language filter works
26. Client-side kind filter works

**Status**: `[x]` Implemented (5 specs)

### P9.4: Integration — Wire into MCP search tool

**Source**: `src/chiasmus/mcp_server/tools/search.cr` (update)

- Accept optional `languages` and `kinds` filter params
- Build CodeIndex from Discovery items instead of (or alongside) Graph pipeline
- Backward compatible: existing `chiasmus_search` API unchanged when filters not specified

### P9.5: Per-Language Default Configs

**Source**: `src/chiasmus/search/code_index.cr` (registry of default configs)

```crystal
module CodeIndexDefaults
  DEFAULT_CONFIGS = {
    "go":         CodeIndexConfig.new(indexed_kinds: ["function", "method", "class", "interface"].to_set),
    "typescript":  CodeIndexConfig.new(indexed_kinds: ["function", "method", "class", "interface", "type"].to_set),
    "python":      CodeIndexConfig.new(indexed_kinds: ["function", "class"].to_set),
    "java":        CodeIndexConfig.new(indexed_kinds: ["function", "method", "class", "interface"].to_set),
    "rust":        CodeIndexConfig.new(indexed_kinds: ["function", "class", "interface"].to_set),
    "ruby":        CodeIndexConfig.new(indexed_kinds: ["function", "method", "class", "interface"].to_set),
    "crystal":     CodeIndexConfig.new(indexed_kinds: ["function", "method", "class", "interface"].to_set),
    # ... all 18 languages
  }
end
```

## Acceptance Criteria

- `[ ]` 18+ language extractors feed into a unified `CodeIndex`
- `[ ]` 18+ language-specific default configs
- `[ ]` Builder fluent API matches Crig conventions
- `[ ]` Crig `InMemoryVectorStore(CodeDocument)` stores documents alongside vectors
- `[ ]` Search supports filtering by language and kind
- `[ ]` 17+ TDD specs pass (P9.1 through P9.3)
- `[ ]` Format + lint clean on new files
- `[ ]` Existing `chiasmus_search` tool unchanged (backward compat)
