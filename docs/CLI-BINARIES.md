# CLI Binaries

`shard.yml` builds these executables. They split into the **MCP server** family
(LLM-facing) and the **parity toolchain** family (porting/verification). All
parity binaries consume or emit Prolog facts (`defines/5`, `calls/2`, …) via
`chiasmus-facts` and share the rule-data schema in
[`parity-rule-data.md`](parity-rule-data.md).

| Binary | Family | One-liner |
|---|---|---|
| `chiasmus` | server | MCP server (stdio / streamable HTTP) over the graph + formal-verification tools |
| `chiasmus-agent` | server | interactive, graph-aware formal-solving CLI |
| `chiasmus-grammar` | toolchain | install/compile/update/cache tree-sitter grammars |
| `chiasmus-discover` | toolchain | enumerate declarations of a source tree (TSV) |
| `chiasmus-facts` | toolchain | extract layer-A Prolog facts from a source tree |
| `chiasmus-parity` | toolchain | curated-ledger parity report + reconciliation/diff formats |
| `chiasmus-plan` | toolchain | plan a port from source facts (rank/slice/seed/track) |
| `chiasmus-complete` | toolchain | completion gate over the curated ledger |

---

## `chiasmus` — MCP server

Starts the Model Context Protocol server that exposes the graph and
formal-verification tools (`chiasmus_graph`, `chiasmus_verify`, `chiasmus_map`,
`chiasmus_review`, …). Runs over stdio by default.

```bash
chiasmus                 # MCP server over stdio
chiasmus --version
chiasmus --healthcheck   # in-memory MCP handshake, no child process
chiasmus --streamable PORT   # HTTP streamable transport (debugging)
```

See [ARCHITECTURE.md](ARCHITECTURE.md) and [../README.md](../README.md).

## `chiasmus-agent` — interactive agent CLI

A graph-aware, LLM-backed CLI for asking formal/verification questions about
code files. Either runs a formal solve (`--ask`) or a graph analysis over the
provided files.

```bash
chiasmus-agent [options] [command] [question...]
```

## `chiasmus-grammar` — grammar manager

Installs, compiles, updates, and caches the tree-sitter grammars the other
binaries need.

```bash
chiasmus-grammar [command] [options]
chiasmus-grammar list
chiasmus-grammar add <url|package|path> [options]
chiasmus-grammar remove LANGUAGE
chiasmus-grammar compile LANGUAGE
chiasmus-grammar batch LANGUAGE1,LANGUAGE2,...
```

## `chiasmus-discover` — declaration enumeration

Tree-sitter-backed declaration enumeration. Emits `{path}::{kind}::{name}` TSV
matching the parity inventory conventions; used to bootstrap generated manifests.

```bash
chiasmus-discover --language LANG --dir DIR [--parser auto|tree-sitter|regex] [--cache-dir DIR]
```

For Java, Crystal, and Go, `--cache-dir` shares a versioned per-file
graph-plus-discovery extraction with `chiasmus-facts --cache-dir`. Content edits
invalidate that result on the next run. Other languages retain their existing
discovery path while adapters are promoted.

## `chiasmus-facts` — fact extraction

Extracts language-neutral, layer-A Prolog facts from a source tree — the
structural/relationship layer all parity tools consume.

Emits: `defines/5`, `qualified_name/3`, `signature/3`, `calls/2`, `calls_in/3`,
`imports/3`, `exports/2`, `contains/2`, `entry_point/1`, `entry_point_file/2`,
plus derived rules (`reaches/2`, `path/3`, `dead/1`, …).

```bash
chiasmus-facts --language LANG --dir DIR [options]
  --entry-point NAME     entry point for reachability/dead-code (repeatable)
  --exclude GLOB         skip paths/segments matching GLOB (repeatable)
  --insights             also emit community/2, cohesion/2, hub/2, bridge/2
  --cache-dir DIR        enable persistent per-file extraction cache
  --repo-key KEY         override cache repo key
  --cache-max-bytes N    max bytes retained in the cache repo
  --profile              emit timing profile to stderr
```

Exit `0` on success, `1` when no files are found or extraction fails.

## `chiasmus-parity` — parity report + reconciliation

Reads a curated inventory and reports per-row parity, or emits alternative
formats for reconciliation/diff. This is the workhorse for mapping a source tree
to a Crystal port.

```bash
chiasmus-parity --inventory FILE [options]
  --root DIR                 repo root for relative crystal dirs
  --crystal-dir DIR          Crystal source/spec directory (repeatable)
  --rules FILE               conversion rules TSV
  --map-rules FILE           cross-language normalization rules YAML (see parity-rule-data.md)
  --parser MODE              auto|tree-sitter|regex
  --source-facts FILE        source graph facts
  --crystal-facts FILE       Crystal graph facts
  --source-declarations FILE optional source typed declaration JSONL for bundle sidecar
  --target-declarations FILE optional target typed declaration JSONL for bundle sidecar
  --format FORMAT            tsv | completion-facts | maps | maps-prolog | surfaces | divergences
  --bundle-dir DIR           write maps.tsv, surfaces.tsv, maps.pl, port-concepts.jsonl, and optional divergences.tsv together
```

`--format` values:

- `tsv` — the classic per-row parity report (name/kind match + structural drift).
- `completion-facts` — Prolog facts for the completion gate (consumed by
  `chiasmus-complete`).
- `maps` — `maps_to` reconciliation: `matched` / `ambiguous` / `unmapped_source`,
  with owner-aware `basis`.
- `maps-prolog` — self-contained Prolog program (`maps_to/2`, `surface_ok/1`,
  `incomplete/1`) queryable via `swipl` or the MCP `chiasmus_verify` tool.
- `surfaces` — typed surface diff (arity drift on matched method pairs).
- `divergences` — joins `maps` against the curated ledger, flagging
  `falsely_missing` / `falsely_ported`.

Use `--bundle-dir DIR` with both facts files (and optionally `--inventory`) to
load the graphs and reconcile once, then render all reconciliation formats.
The versioned `port-concepts.jsonl` sidecar has one record per source mapping.
It assigns a path-independent `port:v1` ID only to a unique one-to-one match
authorized by an explicit rename rule. Direct, ambiguous, unmapped, and
consolidated matches have a null ID. Legacy fact IDs remain as references.
Optional `--source-declarations` and `--target-declarations` inputs populate
the local `source_declaration_id` and `target_declaration_id` fields. Each
nonblank JSONL line is one serialized `Graph::FileExtraction::Result` with a
`declarations` array. The join uses exact `legacy_aliases` only, accepts only
the configured source/target language, and leaves stale or duplicate aliases
unjoined. With no typed input, those fields remain null; the current
`chiasmus-facts` CLI does not yet export typed JSONL directly.
This reduces repeated work in the cross-language parity skill while leaving
the individual `--format` invocations available for older scripts. With
`chiasmus-facts --cache-dir DIR`, snapshots are named from the input contents
and extractor version, so an older facts file continues to reference its
original graph after a later run updates the same source tree.

## `chiasmus-plan` — port planner

Turns source facts into an ordered port plan over the existing graph analyses.

```bash
chiasmus-plan <rank|safe|slice|seed-parity|track|audit|refresh> --facts FILE [options]
  --inventory FILE       curated ledger to join
  --parity-report FILE   parity TSV for tracking
  --parity-plan FILE     plans/parity.md for status parsing
  --root DIR             repo root
  --top N                cap results
  --format tsv|json|markdown
  --previous-facts FILE  for `refresh` (current-vs-previous drift)
```

## `chiasmus-complete` — completion gate

Answers "is the port done?" against the **curated ledger plus source facts**. For
every inventory row reachable from the upstream entry points, it decides whether
the row is *complete*, and exits non-zero while reachable work remains — the
CI/signoff gate for a port.

A row is **complete** when all hold:

1. ledger status is `ported`;
2. it has a Crystal match (not `-`);
3. it is a structural match (or structural checks do not apply but it matched);
4. it is tested (a spec is referenced via `crystal_refs` or `test_refs`).

Rows that are reachable but not complete are `incomplete` (unless `skipped` /
`intentional_divergence`). Non-reachable rows are ignored.

```bash
chiasmus-complete --inventory FILE --source-facts FILE \
  [--crystal-facts FILE | --parity-report FILE] [options]
  --root DIR             repo root
  --crystal-dir DIR      Crystal source/spec directory (repeatable; default src,spec)
  --rules FILE           conversion rules TSV
  --parser MODE          auto|tree-sitter|regex
  --query MODE           status | complete | incomplete
  --format FORMAT        tsv | ids   (list output)
```

- `--query status` prints `status`, `complete_count`, `incomplete_count` and
  returns **exit code 2** when anything is incomplete, else `0`.
- `--query complete|incomplete` lists rows (`tsv`) or ids (`ids`); returns `0`.

Example:

```bash
chiasmus-complete --inventory plans/inventory/java_port_inventory.tsv \
  --source-facts /tmp/java.pl --crystal-facts /tmp/crystal.pl --query status
# status	incomplete
# complete_count	2171
# incomplete_count	10258
```

---

## How the parity toolchain fits together

```text
chiasmus-grammar          chiasmus-discover
      │                         │
      ▼                         ▼
  (grammars)  ──────────▶  declarations ──▶ plans/inventory/<lang>_port_inventory.tsv
                                                   ▲
chiasmus-facts ──▶ source.pl / crystal.pl ──▶ chiasmus-parity ──▶ parity.tsv / maps / surfaces / divergences
                                                   │
                                                   ▼
                                            chiasmus-complete  (gate)
                                            chiasmus-plan      (what next)
```

Rule data for reconciliation lives in the port repo (recommended
`plans/parity_rules.yml`); see [`parity-rule-data.md`](parity-rule-data.md) and
the `cross-language-crystal-parity` skill's `reconcile_parity.sh` driver.
