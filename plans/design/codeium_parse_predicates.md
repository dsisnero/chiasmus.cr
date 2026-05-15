# Codeium-Parse Predicate Design

## Goal

Port the useful parts of codeium-parse query behavior into the Crystal discovery pipeline while preserving the existing `QueryExtractor` API. The design keeps language-specific extraction declarative and keeps predicate evaluation isolated from extractor registration and file traversal.

## Architecture

- `QueryExtractor` remains the base abstraction for language-specific discovery.
- Existing `queries` stay compatible for simple tree-sitter captures.
- `predicate_queries` adds codeium-parse-style query support without changing callers.
- `PredicateEvaluator` owns predicate interpretation and returns metadata for each accepted match.
- `Pipeline` and `ExtractorRegistry` stay closed for modification; adding a language means adding a new extractor and grammar mapping.

## Predicate Semantics

Supported predicates:

- Filters: `#eq?`, `#not-eq?`, `#match?`, `#not-match?`
- Node constraints: `#has-type?`, `#has-parent?`, `#not-has-parent?`
- Metadata/transforms: `#set!`, `#select-adjacent!`, `#lineage-from-name!`, `#strip!`

Invalid regex patterns and query failures are non-fatal. A bad predicate query should skip that query, not fail the whole inventory run.

## Output Contract

Extractor output remains `Discovery::Item` with stable IDs:

```text
{file_path}::{kind}::{name}
```

Predicate metadata is used to improve names and capture docs, parameters, return types, imports, references, and fields, while keeping the inventory TSV format stable.

## Verification

- Predicate parser specs live in the `tree_sitter` shard.
- Predicate evaluator and extractor integration are covered by Crystal specs.
- Codeium-parse golden parity is covered by `spec/chiasmus/discovery/codeium_parse_golden_spec.cr`.
- `plans/inventory/codeium_parse_coverage.tsv` is the coverage ledger for query kinds, intentional divergences, and unsupported injection-only files.
