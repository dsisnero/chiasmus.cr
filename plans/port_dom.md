# PortDOM: Typed API-Surface IR For Cross-Language Parity

**Status:** sketch / planning
**Created:** 2026-10-09
**Related:** [`plans/design/semantic_ir.md`](design/semantic_ir.md), [`plans/parity_skills.md`](parity_skills.md), `src/chiasmus/parity.cr`, `src/chiasmus/graph/ir.cr`

## Why

Today's structural parity lives in `Parity::Structural` (`src/chiasmus/parity.cr:247`).
Per mapped inventory row it compares:

- presence (`defined?`) and export visibility (`exported?`)
- entry-point membership
- normalized `imports`, direct `calls`, and `contains`

This is a **call-graph-level** comparison. It catches missing symbols and call /
import / containment drift, but it is blind to everything that actually
distinguishes a faithful port from a nearly-right one:

- method arity, parameter count, parameter types, return type
- property/constant/type-alias kind and shape
- visibility / access modifier drift
- base-type / inherited-interface changes
- naming that normalizes differently per language (`snake_case`, `?`/`!`,
  module nesting, namespace prefixes)

`parity_skills.md` already names this ceiling: *"Verification is still structural,
not semantic."* This plan raises the **structural** ceiling from call-graph to
**typed API surface** — without claiming behavioral proof.

### What DeepWiki says about Kiota (the borrowed idea)

`microsoft/kiota` solves a neighboring problem with a **CodeDOM** + **language
refiners** + **writers**:

- **CodeDOM** = a language-neutral, *typed* IR: `CodeClass`, `CodeMethod`,
  `CodeProperty`, `CodeNamespace`, `CodeEnum`, `CodeType`, `CodeUsing`. Single
  source of truth, built once.
- **Refiners** = ordered per-language transforms. `ILanguageRefiner.RefineAsync`
  over `CommonLanguageRefiner`; e.g. `CSharpRefiner` appends `Async`,
  `RubyRefiner` snake_cases + flattens namespaces, `JavaRefiner` adds
  getters/setters. They preserve intent while adapting idioms.
- **Conventions + writers** = emission driven by `ILanguageConventionService`
  and `CodeElementWriter`s.
- **Parity invariant:** the CodeDOM guarantees *spec-derived structure*; refiners
  preserve intent; **behavior** is proven by per-language test suites.

Kiota's CodeDOM is *generation-oriented* and assumes a neutral semantic model
exists **upstream of** the code (an OpenAPI description). For porting an existing
codebase there is no such model, so a full CodeDOM cannot be the source of truth.
But the *typed-surface* half of the idea — normalize both trees into a shared
typed shape and diff them — is directly applicable and is what this plan
borrows.

`semantic_ir.md` already introduces `IR::SemanticGraph` and an ordered
`Refiner` pipeline and explicitly defers the typed surface layer
("Why Not A Full Kiota-Style CodeDOM"). This plan is the targeted extension of
that IR for the parity/planning/completion consumers, not a second IR.

## Goal

Add a **PortDOM** layer on top of `IR::SemanticGraph`:

1. model the *typed API surface* of each symbol (params, return type, kinds,
   visibility, base types), language-neutrally;
2. add per-language **normalizer** refiner passes so naming/type idioms collapse
   before comparison;
3. diff two PortDOMs (source vs port) into explicit surface statuses;
4. feed the result into the existing `chiasmus-parity` report and the
   `complete/1` / `incomplete/1` completion gate.

## Non-Goals

- **Not a code generator.** No emission, no writers, no source synthesis. Kiota's
  writer half is explicitly out of scope.
- **Not behavior/semantic proof.** This stays structural; behavior remains the
  job of ported upstream tests (`verify_parity_adversarial.sh`).
- **Not a `CodeGraph`/facts replacement.** Facts remain the query/export layer;
  PortDOM is an enriched view above it.
- **Not a second parser.** Reuse the tree-sitter walkers already reachable
  through `chiasmus_graph` / `Graph::Extractor`.
- **No new dependency-only surface.** Every PortDOM element must have a
  downstream consumer (parity report, planner, or completion gate) before it
  lands — same bar as `semantic_ir.md`.

## Design

### 1. PortDOM elements

Extend `IR::SymbolNode` (which already carries `kind`, `signature`,
`qualified_name`, `owner_name`, `span`) with typed surface records. Keep them
immutable value objects so refinement stays deterministic and testable.

```crystal
module Chiasmus::Graph::IR::PortDom
  record TypeRef,
    name : String,            # normalized: "Array(String)", "PDColorSpace", "Nil"
    nullable : Bool = false,
    generic_args : Array(String) = [] of String

  record Param,
    name : String,
    type : TypeRef? = nil,
    default : String? = nil,
    variadic : Bool = false,
    kind : ParamKind = ParamKind::Positional   # Positional | Named | Block | Receiver | Kwarg

  record MethodSurface,
    symbol_id : String,
    name : String,            # normalized simple name
    params : Array(Param) = [] of Param,
    return_type : TypeRef? = nil,
    raises : Array(String) = [] of String,
    static : Bool = false,
    abstract : Bool = false,
    visibility : Visibility = Visibility::Public

  record PropertySurface,
    symbol_id : String,
    name : String,
    type : TypeRef? = nil,
    mutable : Bool = false,
    visibility : Visibility = Visibility::Public

  record TypeSurface,
    symbol_id : String,
    kind : SurfaceKind,       # Class | Struct | Module | Interface | Enum | Alias | Lib
    base_types : Array(String) = [] of String,
    type_params : Array(String) = [] of String,
    visibility : Visibility = Visibility::Public

  # Visibility, ParamKind, SurfaceKind are explicit Kinds (Kiota's
  # CodeClassKind / CodeMethodKind analog), so meaning is never inferred from
  # spelling.
end
```

A `PortDom` value aggregates `types`, `methods`, `properties`, keyed by the
stable `symbol_id` already derived by `IR::Lowering.symbol_id` (`ir.cr:551`).
`symbol_id` is the cross-language identity handle: two codebases that port the
same entity produce the *same* normalized identity after refiner passes, which
is what kills name-only false positives (e.g. a debugger `Stream` matching
`Cos::Stream`).

**Source of surface data:** the walkers already produce `signature` strings for
many languages. Phase P1 derives the structured records from `signature` when
present and from the walker's language metadata otherwise; no walker rewrite is
required to start. Phase P4 promotes the walkers to emit structured surface data
directly (mirrors `semantic_ir.md` Phase 3).

### 2. Normalizer refiner passes (per language)

Reuse the existing ordered `Refiner` pipeline (`ir.cr:473`). Add pure passes:

1. **Common normalization** (existing `CommonNormalizationRefiner`):
   dedupe edges, normalize ids, repair owner/simple-name.
2. **Surface extraction** (`PortDomBuildRefiner`): raise `signature` + walker
   metadata into `MethodSurface` / `PropertySurface` / `TypeSurface`.
3. **Naming normalization** (`CrystalNamingRefiner`, `JavaNamingRefiner`, …):
   - Crystal: `snake_case`, strip trailing `?`/`!` into a suffix flag, collapse
     `::` module nesting to canonical owner, map `Nil`/`Array(T)`/`Set(T)`.
   - Java: strip getter/setter prefix into a property, map `int`→`Int32`,
     `String`→`String`, `List<T>`→`Array(T)`, receivers/packages to owners.
   - mirrors the Kiota refiner split, applied to *analysis*, not generation.
4. **Type normalization** (`TypeNormalizationRefiner`): apply the target's
   `TYPE_MAP` (see `openapi_cr`'s `codegen/conventions.cr` for prior art) so
   `string`/`String`, `int`/`Int32`, `list`/`Array` compare equal.
5. **Surface canonicalization**: sort params, drop parameter names when the
   language/caller semantics don't depend on them, normalize optional/default.
6. **Rename / consolidation maps** (`RenameMapRefiner`, declarative rule data):
   deterministic `old → new` maps for cases no naming rule can derive. These are
   the Kiota `StringExtensions`/reserved-name rule analogs and are where the
   real porting decisions live, e.g.:
   - prefix strip: `CO*`/`PD*` → base name (`COSBase`→`Base`, `COSName`→`Name`,
     `PDDocumentInformation`→`DocumentInformation`)
   - accessor strip: `get_`/`set_`/`is_` → property
   - consolidation/alias: `PDXObject` and contentstream operator classes →
     dynamic dispatch to `process_operator`; `DefaultResourceCache`→`ResourceCache`
   - reserved-word + keyword escaping per the convention descriptor

Passes are ordered, immutable, deterministic, and covered by round-trip specs.
Rename maps are data, not code paths, so they are reviewable and testable on
their own (`maps_to` fixtures).

### 3. Surface diff

Add a `Parity::Surface` comparator consumed by the existing
`Parity::Structural.compare` path. For each mapped source/target pair emit one
`SurfaceReport`:

```crystal
record SurfaceReport,
  source_id : String,
  target_id : String?,
  status : String,               # surface_match | surface_drift | surface_missing_target | surface_unmodeled
  kind_match : Bool,
  arity_match : Bool,
  param_type_matches : Array(String),
  param_type_missing : Array(String),
  return_type_match : Bool,
  visibility_match : Bool,
  base_type_matches : Array(String),
  base_type_missing : Array(String)
```

Statuses compose into the existing `match_status` / `structural_status` columns
as new `signature_status` and `surface_details` fields rather than replacing
them, so existing ledgers and consumers keep working.

### 4. Shared fact schema and `maps_to/2` join

PortDOM gives the in-process model; the parity consumers (Prolog gate, report,
planner) need a normalized *fact* projection. Today facts are language-native
(`defines(File, 'COSBase', class, …)` vs `defines(File, 'Base', class, …)`),
which forces consumers to re-guess identity from spelling. Add a normalized
projection emitted once both sides are refined:

```prolog
% cross-language shared entity schema (CodeDOM-equivalent)
entity(Id, Kind, Name, Parent, Lang).          % Kind is explicit, not inferred
member(EntityId, MemberId, MemberKind).        % MemberKind: method | property | const | param

% join produced by parity after normalization + inventory mapping
maps_to(SourceId, TargetId).                   % same entity, possibly different spelling
maps_to(SourceId, none).                       % source entity with no target counterpart
```

The projection backs new analyses that are pure joins over the two fact sets:

- **Java methods with no Crystal counterpart:** `entity(S, method, _, _, java), \+ maps_to(S, _).`
- **Renamed but present:** `maps_to(S, T), entity(S, _, NS, _, java), entity(T, _, NT, _, crystal), NS \= NT.`
- **Same-signature but suspicious:** `maps_to(S, T), \+ surface_ok(S).`
- **Member-level gap:** `member(S, SM, _), \+ (maps_to(S, T), member(T, TM, _), maps_to(SM, TM)).`

This is the difference between an ad-hoc `def <snake_case>` heuristic (which
produced the debugger-`Stream` false positive and needs manual excludes) and a
principled `maps_to/2` join. It is the highest-leverage way to mechanically
surface the remaining unfaithful rows and "falsely-ported" gaps.

### 5. Language convention descriptor

Mirror Kiota's `ILanguageConventionService` with data, not hardcoding: a
`ConventionDescriptor` per language supplying casing (`snake_case` vs
`PascalCase`), namespace→path mapping, type-name map, keyword/reserved sets, and
the rename/consolidation maps from §2.6. Refiners and the report consult this
descriptor; adding a language means adding descriptor data + (optionally) a
walker, not touching parity internals.

### 6. Wiring

- **Facts:** emit optional `surface/…` Prolog predicates (`param/4`,
  `return_type/2`, `visibility/2`, `base_type/2`) alongside `defines/5`, plus the
  normalized `entity/4` + `member/3` + `maps_to/2` projection (§4), gated behind
  a flag so existing fact consumers are unaffected.
- **Parity report:** add `signature_status` + `surface_details` columns
  (`Parity::CLI.render_tsv`, `parity.cr:1929`).
- **Cross-language analyses:** expose the §4 joins as first-class
  `chiasmus-parity` queries (`--query unmapped-source | renamed | member-gaps`)
  so reconciliation work is mechanical rather than grep-driven.
- **Completion gate:** extend the merged Prolog program so

  ```prolog
  complete(Id) :- reachable_from_entry(Id), ported_item(Id),
                  target_match(Id, _), structural_ok(Id),
                  surface_ok(Id), tested(Id).
  ```

  `surface_ok/1` derives from the `surface/…` facts. `incomplete/1` then reports
  signature-level gaps that name-level parity misses.
- **Skill:** document an MCP-assisted path — `chiasmus_graph` (`analysis=facts`,
  `include_insights`) on source + target, then `chiasmus_verify` (prolog) for
  `incomplete/1` — as an alternative to the bundled CLI binaries. Fold the
  surface columns into `plan_with_chiasmus.sh` / `check_completion_gate.sh`
  output. (This also closes the skill-drift gaps noted in `parity_skills.md`.)

### 7. Concurrency

Per `AGENTS.md` and `docs/ARCHITECTURE.md`: PortDOM build + normalization run
inside the same bounded extraction path. Long-running extraction returns
`Channel(T)` via `IR::Pipeline.refine_async` (`ir.cr:481`); refinement is pure
(deterministic, no shared mutable state); caches stay behind the existing
SQLite/`Sync::Map` boundary. Never block the calling fiber.

### 8. Prolog query layer (decided)

The reconciliation is a relational join, and chiasmus already runs Prolog
(`chiasmus-facts` → `defines/5`/`calls/2`; `Graph::Facts::BUILTIN_RULES` →
`reaches/2`, `path/3`, `dead/1`; `chiasmus-complete` merges source + target +
inventory into `complete/1`/`incomplete/1`). We therefore split the work:

```text
Crystal (lexical + extraction)          Prolog (join + recursion + queries)
  extract tree-sitter facts               maps_to/2
  normalize names / owners                falsely_missing/1, falsely_ported/1
  emit entity/5, member/3,                transitive owner/namespace equivalence
    normalized/2, rename/2,               completion gate (complete/1)
    consolidate/2, owner_alias/2
```

Rationale: string normalization (snake_case, prefix/accessor strip, CamelCase
tokenization) stays in Crystal because it is lexical and hot; the join, the
recursive relations (rename chains, transitive namespace aliases), and ad-hoc
queries move to Prolog. This removes the bespoke Crystal join/divergence code
(`InventoryJoin.best_status`/`divergence_for`/`kind_compatible?`) in favor of
clauses, and lets the same engine answer arbitrary questions via
`chiasmus_verify`.

Two concrete deliverables on this layer:

1. **`owner_aliases` rule data.** Explicit namespace/tie aliases (e.g.
   `pdfwriter → pdf_writer`, `pdmodel → pd_model`) resolved **transitively**, so
   spelling differences that no lexical rule can derive stop producing
   `falsely_ported` noise.
2. **`chiasmus-parity --format maps-prolog`.** Emits a self-contained Prolog
   program (facts + `maps_to/2` + divergence predicates + query rules) runnable by
   `swipl` or the MCP `chiasmus_verify` tool, and foldable into the existing
   completion gate.

`entity/5` includes the owner and language so multi-language sources share one
program; `maps_to/2` is derived, not hand-written, once the projection lands.

## Phases

### P0 — Schema + round-trip (no behavior change)
- Add `PortDom` records + enums to `src/chiasmus/graph/ir.cr` (or `ir/port_dom.cr`).
- `SemanticGraph` → `PortDom` → `SemanticGraph` round-trip preserves symbols.
- **Spec:** `spec/chiasmus/graph/port_dom_spec.cr` (records, ids, enum coverage).
- **Acceptance:** quality gates green; zero change to existing parity output.
- **Status (2026-10-09):** landed in `src/chiasmus/graph/port_dom.cr`
  (`PortDom.build` lowers through `IR.normalize`, classifies symbols into
  `TypeSurface`/`MethodSurface`/`PropertySurface`; `to_code_graph` round-trips).
  P1 (populate params/return types from signatures) is next.

### P1 — Surface extraction from signatures
- `PortDomBuildRefiner` parses existing `signature` strings into surfaces.
- **Spec:** signatures for Crystal + Java fixtures parse to expected records.
- **Acceptance:** surfaces populated for ≥ 90% of `defines` symbols that carried
  a non-empty signature in a sample repo.
- **Status (2026-10-09):** landed as `PortDom.parse_signature` (top-level-comma
  and bracket-depth aware; `name: Type` and Java-style `Type name`; `->` return;
  `?`-nullable; `...` variadic). `PortDom.build` populates `MethodSurface`
  params/return from `symbol.signature`. Coverage is bounded by signature
  availability: the Rust walker emits signatures, while the Java and Crystal
  walkers do not yet (that is P5). So the ≥90% acceptance applies only once P5
  lands for those languages; P1 is complete for languages that emit signatures.

### P2 — Normalizer refiners + conventions
- `CrystalNamingRefiner`, `JavaNamingRefiner`, `TypeNormalizationRefiner`.
- **Spec:** red-green fixtures proving `getFoo`/`foo`, `int`/`Int32`,
  `List<T>`/`Array(T)`, `?`/`!` suffixes, `::` nesting all normalize equal.
- **Acceptance:** normalization is deterministic and idempotent (refine twice == once).
- **Status (2026-10-09):** type normalization delivered via `Rules::Side.type_map`
  + `Surface::TypeNormalizer` (case-insensitive `name -> canonical`), seeded for
  Java/Crystal in `pdfbox/plans/parity_rules.yml` (`void`↔`Nil`, `int`↔`Int32`,
  `boolean`↔`Bool`, …). Return types now compare and report `return_match`
  (1,538 true on PDFBox). **Deliberately not a hard status yet:** with primitives
  mapped but class names/generics unmapped, return-type status produced 1,010
  mismatches (vs 228 arity-only), so it stays informational until class-name and
  generic normalization lands. `List<T>`/`Array(T)` and `?`/`!` normalization
  remain open.

### P3 — Surface diff + report columns
- `Parity::Surface`; add `signature_status`, `surface_details` to TSV.
- **Spec:** fixture pairs exercising `surface_match`, `surface_drift`,
  `surface_missing_target`, `surface_unmodeled`.
- **Acceptance:** a known arity/return-type deviation in a fixture is flagged
  where name-level parity passes.
- **Status (2026-10-09):** landed as `Parity::Surface` (`src/chiasmus/parity/surface.cr`)
  with a dedicated `--format surfaces` TSV (avoids destabilizing the 12-column
  parity report). Compares arity (reliable cross-language) and reports return
  types informationally; statuses `surface_match`/`surface_mismatch`/
  `surface_unmodeled`. `PortDom.build` was switched to the O(n) lowering so the
  12k-symbol PDFBox graph diffs in ~2.6s. On PDFBox: 2,267 match / 228 arity
  drift / 7,731 unmodeled. Return-type equivalence awaits the convention
  descriptor.

### P3.5 — Shared fact projection + `maps_to/2` join
- Emit `entity/4` + `member/3` normalization; produce `maps_to/2` from
  normalization + inventory mapping.
- Expose cross-language queries: unmapped-source, renamed-but-present,
  member-gaps.
- **Spec:** fixture with a renamed entity + a missing member yields the expected
  `maps_to/2` rows and query results.
- **Acceptance:** a real consolidation map (e.g. `COS*`→`*`, operator classes→
  `process_operator`) reconciles rows that name-only matching reported as
  missing, with no manual excludes.
- **Status (2026-10-09):** delivered via `--format maps-prolog` (§8): `entity/5`,
  `member/3`, `normalized/2`, `maps_to/2`, `map_status/2`, `inventory_entity/2`,
  plus `surface_status/2` and query rules. `surface_ok/1` is folded into
  `complete/1`, moving 204 ledger-`ported` arity-drift rows out of `complete`
  (2,375 -> 2,171) on PDFBox. Verified under SWI-Prolog.

### P4 — Completion gate wiring
- Emit `surface/…` facts (flag-gated); extend `complete/1` with `surface_ok/1`.
- **Spec:** `chiasmus-complete --query incomplete` surfaces a signature-level gap.
- **Acceptance:** `incomplete/1` includes at least one signature-only gap not
  reported by the current gate.
- **Status (2026-10-09):** delivered through the Prolog projection (§8):
  `maps-prolog` emits `surface_status/2` and `complete/1` requires `surface_ok/1`
  (bridged via `inventory_entity/2`). On PDFBox, `incomplete/1` grows by 204
  (surface-only gaps not reported by the name/structural gate). Wiring this into
  the standalone `chiasmus-complete` binary (rather than the emitted program)
  remains optional follow-up.

### P5 — Walkers emit structured surface (parity with Phase 3 of `semantic_ir.md`)
- Promote selected walkers (Crystal, Java, TypeScript) to emit surface directly.
- **Acceptance:** signature-parsing fallback becomes unused for those languages.
- **Status (2026-10-09):** Java and Crystal walkers now emit signature strings
  (`walkers/java.cr` uses the `parameters`/`type` fields; `walkers/crystal.cr`
  reads the `param_list` and post-`:` return type). `PortDom.parse_signature`
  handles defaults (`= value`), generics, and varargs, so extracted Java/Crystal
  methods now populate `MethodSurface` params/return (spec: extracted Java
  `add(int a, int b) -> int` yields `["a","b"]` / `int`). **Facts serialization
  closed:** `chiasmus-facts` now emits `signature/3` and `Structural.load_facts`
  reattaches it, so the file-based `chiasmus-parity` path carries signatures
  (verified: 255 signatures on the `pdfbox` `cos` package). P3/P3.5 can now diff
  signatures on `pdfbox`.

### P6 — Real-repo validation + skill wiring
- Run against a real port (e.g. `pdfbox` Java → Crystal, `chiasmus` TS → Crystal).
- Update the `cross-language-crystal-parity` skill docs/scripts (see Open
  Questions) and add the MCP path.
- **Acceptance:** report on a real repo shows actionable signature drift and the
  completion gate materially changes, with signoff green.
- **Status (2026-10-09):** real-repo validation done on `pdfbox` (Java → Crystal)
  — 56 `falsely_missing`, 824 `falsely_ported`, 228 surface arity drifts, and the
  completion gate moves 204 ported rows out via `surface_ok/1`. Skill wiring:
  `crystal_forge` ships a new `scripts/reconcile_parity.sh` (facts → maps /
  surfaces / maps-prolog / divergences), `sync_chiasmus_release_binaries.sh` now
  copies `chiasmus-facts`/`-plan`/`-complete`, and `SKILL.md` documents the
  reconciliation flow + rule data + MCP (`chiasmus_verify`) path. Repo-side root
  cause fixed: `.github/workflows/release.yml` now builds all eight binaries.

### P7 — Transitive owner/namespace aliases
- Add `owner_aliases` rule data; resolve aliases transitively during owner
  matching.
- **Spec:** alias chain `a -> b -> c` resolves; pdfbox aliases
  (`pdfwriter`↔`pdf_writer`, `pdmodel`↔`pd_model`) reduce `falsely_ported`.
- **Acceptance:** `falsely_ported` on the PDFBox corpus drops materially versus
  the leaf-only baseline, with `falsely_missing` unchanged.

### P8 — `maps-prolog` projection + completion fold
- Emit `entity/5`, `member/3`, `normalized/2`, `rename/2`, `consolidate/2`,
  `owner_alias/2`, `maps_to/2`, and divergence predicates as a self-contained
  Prolog program (`chiasmus-parity --format maps-prolog`).
- Include query rules (`falsely_missing/1`, `falsely_ported/1`) and document
  folding them into the `chiasmus-complete` gate / MCP `chiasmus_verify`.
- **Spec:** golden program for a fixture; SWI-Prolog query returns expected rows.
- **Acceptance:** the divergence queries and the completion gate run from one
  program; output matches the Crystal `--format divergences` result.

### P9 — Member owner identity (2026-10-09)
- **Problem:** members (Java enum constants, Crystal consts/enum members) were
  keyed by leaf name only (bare `qualified_name`), so leaf collisions produced
  false matches (e.g. `XReferenceType.NORMAL` vs `BlendMode.Normal`) and
  Crystal consts had no owner.
- **Change:** Java `walkers/java.cr` `extract_java_enum_members` and Crystal
  `walkers/crystal.cr` enum-member/const paths now emit the enclosing type in
  `qualified_name` (`Kind.NAME`) plus a `contains` edge; the reconciler's owner
  filter then applies.
- **Measured (PDFBox):** `falsely_missing` 56 → 17 (remaining rows are genuine
  presence signals); maps entity count 11,989 → 12,065, matched 3,152 → 3,241.
- **Also:** `--format divergences` gained `target_file`, `target_owner`, and
  `basis` columns for triage.
- **Scope exclusion landed:** `chiasmus-facts --exclude GLOB` (repeatable;
  segment or glob match) plus `PORT_SCOPE_EXCLUDE` in `reconcile_parity.sh`
  (comma-separated), so out-of-scope trees stop inflating. Measured on PDFBox:
  12,065 → 10,605 entities with `debugger,tools,benchmark,examples` excluded.
- **Kind-aware tie-break landed:** when a compatible set is still ambiguous,
  prefer the single candidate whose kind exactly equals the source kind
  (function vs method, class vs module). Measured: matched 3,241 → 3,257,
  ambiguous 1,655 → 1,639.
- **Module-leaf owners verified:** the reconciler already compares the owner
  *leaf*, so Crystal `Pdfbox::IO.MemoryUsageSetting.setup_main_memory_only`
  matches Java `MemoryUsageSetting.setupMainMemoryOnly` (basis `owner`); a spec
  locks it in. No code change was needed for item 2.
- **Same-name attachment bug fixed:** `Structural.load_facts` keyed
  `qualified_name`/`signature` by `{file, name}`, so repeated same-named members
  in one file (nested enums, overloads — e.g. `Type1KeyWord.HSTEM`,
  `Type2KeyWord.HSTEM`, `CharStringCommand.HSTEM`) all collapsed to the last qn.
  Now attached in emission order (multiplicity-preserving). Measured: matched
  3,257 → 3,620, ambiguous 1,639 → 1,464, unmapped 7,169 → 6,981.
- **Remaining:** the ruleset iteration (fontbox prefix strips, renames,
  operator/type4 consolidate) is pdfbox repo data.

### P10 — Inherited/interface member matching (2026-10-09)
- **Problem:** a Java base-type member (`PDAbstractContentStream.beginText`,
  `RandomAccessRead.read`, `PDFontLike.*`) is implemented on each Crystal
  concrete subtype, so the strict owner join leaves ~500+ ledger-`ported` rows
  `unmapped_source` — a 1:N shape that no 1:1 `owner_alias`/`rename` can express.
- **Change:** new rule `match_inherited`. When the strict owner join fails for a
  **callable** member, fall back to name + signature, but only when the canonical
  member is spread across **≥2 distinct target owners** (the interface signature)
  and both signatures agree on arity. Those rows become `ambiguous` with
  `basis: member` (resolved, not unmapped; the concrete owner is not guessed).
  The ≥2-owner guard rejects coincidental single-owner collisions
  (`IndexedColorant.getColor` vs `BlendMode.color` stay unmapped). The exact-kind
  tie-break is disabled for inherited candidates so they stay ambiguous.
- **Prefix-strip fix:** `strip_prefix` now uses the longest matching prefix that
  leaves a valid remainder (uppercase/`_`-leading), so `PDFontLike` → `FontLike`
  (not `ontLike`) while `PDFDocEncoding` → `DocEncoding`.
- **Divergences:** `--format divergences` gained a stable `target_id` column
  (alongside `target_file`/`target_owner`/`basis`).
- **Measured (PDFBox, `match_inherited: true`):** `falsely_ported` 824 → 422,
  `falsely_missing` 17 → 8, ambiguous 1,464 → 2,483 (inherited rows resolve to
  ambiguous), unmatched 6,976 → 5,959. Strict `basis: owner` matches unchanged
  (3,623) — no new false positives.

## Thin-Slice Entry Points

Two ways to prove value early, before the full P0–P6 stack:

- **(a) Refiner-map + `maps_to` reconciliation pass.** Hand-encode the small set
  of consolidation/rename rules (`COS*`→`*`, `PDDocumentInformation`→
  `DocumentInformation`, operator classes→`process_operator`,
  `DefaultResourceCache`→`ResourceCache`, accessor stripping) as data, then run
  the §4 join against a real port (e.g. `pdfbox`) to mechanically surface
  unmapped rows and member gaps. Lowest effort, immediate signal, and it directly
  tests whether the schema handles the hard cases.
- **(b) `chiasmus_craft` cross-language-parity template.** Prototype a
  `prolog`-solver template in the skill library encapsulating `maps_to/2` +
  member-diff queries, so the reconciliation is a reusable, invoked artifact
  rather than a bespoke script.

**Recommendation:** do **(a) first** as a disposable spike on one real port.
Kiota's lesson is that the durable knowledge is in the refiner rules, and you
only learn the right shared-schema shape once those rules exist. Promote (a) into
the §1/§4 schema (P0–P3.5) once the rules stabilize, then wrap the stable shape as
the (b) template at P6.

**Status (2026-10-09):** thin slice (a) landed. `Parity::Rules` +
`Parity::Reconcile` (`src/chiasmus/parity/rules.cr`, `reconcile.cr`) load
`plans/parity_rules.yml`, normalize both graphs, and emit `maps_to`-style
rows via `chiasmus-parity --map-rules FILE --format maps`. Authoring guide:
`docs/parity-rule-data.md`; worked example: `pdfbox/plans/parity_rules.yml`.
Owner-aware tie-breaking (`match_owner: true`) then landed too: canonical-key
collisions are resolved by package/module owner leaf (source owner from Java
package, target owner from `contains` module membership), and the owner is made
**authoritative** (an owner-conflicting name match becomes `unmapped_source`
instead of a silent match). On the PDFBox corpus that moved the distribution
from 2,549 matched / 4,465 ambiguous / 4,975 unmapped to 3,152 matched / 1,524
ambiguous / 7,313 unmapped — resolved ties down, generic-name false matches
rejected. `--format divergences` then joins `maps_to` against the curated
inventory and flags ledger-vs-structure disagreements: on PDFBox it reports 56
`falsely_missing` (down from 804 name-only, now dominated by `const`/`enum`) and
825 `falsely_ported` (method-noisy; needs review). Remaining v2 gap: method-level
identity is still weak because the Java extractor emits inconsistent qualified
names (bare vs owner-qualified) and renamed target classes break strict owner
matching; explicit namespace-alias rules (the `plans/design/semantic_ir.md`
convention descriptor) and a typed surface are the next refinements. A generic
"flatten owner separators" variant was tried to bridge `pdfwriter`/`PdfWriter`
but measured net-negative and was reverted.

**Status (2026-10-09, Prolog layer §8):** P7 (`owner_aliases`, transitive) and
P8 (`--format maps-prolog`) landed. `owner_aliases` is a small win on PDFBox
(`falsely_ported` 825 -> 824; only 4 real leaf-spelling pairs exist, so the
`falsely_ported` noise is method-identity, not owner spelling). `maps-prolog`
emits `entity/5`, `member/3`, `normalized/2`, `rename/2`, `consolidate/2`,
`owner_alias/2`, `maps_to/2`, `map_status/2`, `inventory_item/5`,
`inventory_entity/2`, `divergence/3`, and query rules; under SWI-Prolog the
recomputed join agrees exactly with the Crystal counts (`falsely_missing=56`,
`falsely_ported=824`) and adds `incomplete/1` (10,054) and
`renamed_but_present/2` (2,565). The join now lives as clauses, so transitive
rename/alias rules and ad-hoc queries need no Crystal changes.

## Risks

- **Signature string fidelity.** Walker `signature` strings may be lossy for
  some languages; P1 measures coverage and P5 fixes the gaps. Statuses include
  `surface_unmodeled` so unknown surfaces never read as a false match.
- **Over-normalization.** Aggressive type/name normalization can mask real
  drift. Mitigation: normalizer fixtures pin exactly what collapses, and the
  raw values stay attached for audit.
- **Scope creep toward CodeDOM/generation.** Guarded by Non-Goals and the
  `semantic_ir.md` branch-exit bar: a PortDOM element only lands if it changes a
  parity/planner/completion outcome.
- **Determinism.** Refiners must sort/order inputs; pinned by idempotence specs.

## Open Questions

1. Where should the skill-side surface output live — new TSV columns in
   `parity.tsv`, or a sibling `surface.tsv`? (Resolved: a dedicated
   `--format surfaces` TSV, so the 12-column parity report stays stable.)
2. Should `PortDom` be a distinct module (`Graph::IR::PortDom`) or fields folded
   onto `SemanticGraph`? (Resolved: distinct `Graph::PortDom`, built via the O(n)
   lowering.)
3. Which real repo becomes the P6 validation target first — `pdfbox` (Java, rich
   surface, large) or `chiasmus` (TS, already the parity self-target)? (Resolved:
   `pdfbox`.)
4. Does the skill-sync fix (ship `chiasmus-facts`/`-plan`/`-complete` in releases
   + copy them in `sync_chiasmus_release_binaries.sh`) land alongside P3 or P6?
   (Resolved: P6 — release workflow builds all eight binaries and the sync script
   copies the full set.)
