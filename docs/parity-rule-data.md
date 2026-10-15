# Cross-Language Parity Rule Data

This guide explains how to add **rule data** so `chiasmus-parity --format maps`
can reconcile a foreign-language source tree against a Crystal port by entity
identity instead of raw name spelling.

The worked example throughout is the **Apache PDFBox (Java) → Crystal** port
(`dsisnero/pdfbox`), but the format is language-agnostic and works for any
grammar-backed source language.

## Mental model

```text
Java facts ──normalize(source rules)──┐
                                       ├─► canonical key ──► maps_to(Source, Target)
Crystal facts ──normalize(target rules)┘
```

Each side is normalized into a shared **canonical key**. Two symbols match when
their canonical keys are equal and their kinds are compatible. This replaces
name-only matching and ad-hoc `snake_case` heuristics with a declarative,
reviewable join.

The output makes three things visible mechanically:

- `matched` — exactly one compatible target for the canonical key
- `ambiguous` — more than one compatible target (a name collision, e.g. a
  debugger `Stream` and `Cos::Stream` both normalizing to `stream`)
- `unmapped_source` — no compatible target (a genuine gap, or a missing rule)

## Where rule data lives

Store rules in the port repo (not in the tooling):

```text
pdfbox/
  plans/parity_rules.yml
```

The parity skill / CLI locates them via `--map-rules plans/parity_rules.yml`.

## Running a reconciliation

```bash
CHIASMUS=/path/to/chiasmus.cr

# 1. Extract structural facts for each side.
"$CHIASMUS/bin/chiasmus-facts" --language java    --dir vendor/pdfbox > /tmp/java.pl
"$CHIASMUS/bin/chiasmus-facts" --language crystal --dir src          > /tmp/crystal.pl

# 2. Reconcile.
"$CHIASMUS/bin/chiasmus-parity" \
  --source-facts  /tmp/java.pl \
  --crystal-facts /tmp/crystal.pl \
  --map-rules plans/parity_rules.yml \
  --format maps > /tmp/maps.tsv
```

Output is TSV:

```
# rules=plans/parity_rules.yml
# total=11989 matched=3152 ambiguous=1524 unmapped=7313
source_id	source_name	source_kind	source_owner	canonical	target_id	target_name	target_kind	target_owner	status	basis
vendor/.../cos/COSBase.java::class::COSBase	COSBase	class	cos	base	src/pdfbox/cos.cr::class::Base	Base	class	cos	matched	direct
```

`basis` records which rule produced the key: `direct`, `renamed`,
`consolidated`, or `owner` (resolved via owner-aware tie-breaking).

## Schema reference

```yaml
version: 1
source_language: java        # included in reviewed PortConceptId derivation
target_language: crystal     # included in reviewed PortConceptId derivation

match_owner: false           # break canonical-key ties by owner leaf
match_inherited: false       # match base/interface members across concrete owners

source:                      # how to normalize SOURCE symbols
  strip_namespace:           # leading qualified-name fragments to remove
    - "org.apache.pdfbox."
  strip_prefix:              # leading simple-name prefixes (longest match wins)
    - COS
    - PD
  strip_accessor: true       # strip get/set/is -> base name
  type_map:                  # type name -> canonical token (case-insensitive)
    void: nil
    int: int
    boolean: bool

target:                      # how to normalize TARGET symbols
  strip_namespace: ["Pdfbox::"]
  strip_prefix: [COS, PD, PDF]
  strip_accessor: false
  type_map:
    Nil: nil
    Int32: int
    Bool: bool

renames:                     # explicit source -> target (post-normalization)
  - source: DefaultResourceCache
    target: ResourceCache

consolidate:                 # many-to-one glob source -> target
  - source: "Operator*"
    target: process_operator
    reason: operator classes dispatch via process_operator
```

All keys are optional; omitted sections default to "no normalization".

### Normalization order (per side)

1. `strip_namespace` — applied to the raw (possibly qualified) name.
2. Take the **simple name** (segment after the last `.` or `::`).
3. `strip_prefix` — longest prefix first; only stripped when a residual name
   remains (`COSBase` → `Base`, but never `COS` → `""`).
4. `strip_accessor` — strips `is`/`get`/`set` **only when followed by an
   uppercase letter or `_`**, so `getOpenAction` → `OpenAction` but `island`
   is untouched.
5. Canonicalize to a snake_case key via `Parity::Naming.normalize_token`
   (`DocumentInformation` → `document_information`, `Cos::Stream` → `stream`).

### Rename and consolidate semantics

- `renames[].source` is matched against the **normalized source name** (steps
  1–4 above), not the raw name. `target` is canonicalized the same way target
  symbols are, so `target: ResourceCache` and a Crystal `ResourceCache` meet at
  `resource_cache`.
- `consolidate[].source` is a glob (`*` wildcard) matched against the normalized
  source name. Consolidation rules **bypass the kind-compatibility check**, so a
  source class family may map to a single target method.

### Owner-aware tie-breaking (`match_owner`)

Canonical keys are simple-name based, so unrelated entities can collide
(`Cos::Stream` and `PDStream` both canonicalize to `stream`; a generic `call`
name appears on many classes). With `match_owner: true`, the owner leaf is
**authoritative**: candidates whose known owner leaf differs from the source
owner leaf are dropped, and candidates with an unknown owner stay eligible.

- More than one remaining candidate → `ambiguous`.
- Exactly one, whose owner leaf matches → `matched`, `basis: owner`.
- None remaining → `unmapped_source` (the name match was an owner conflict).

This is what keeps precision high: a `PDFDebugger.call` no longer silently
matches `DecompressObjectstreams.call`. The cost is that owner-conflicting name
matches move from `matched`/`ambiguous` to `unmapped_source`.

Owner (package / module) is resolved from, in order:

1. the owner part of `qualified_name` (methods), e.g. `COSArray.accept` →
   `COSArray`;
2. the `contains` parent (Crystal module membership), e.g.
   `contains('Pdfbox::Cos', 'Stream')` → `Pdfbox::Cos`;
3. the enclosing directory name (Java package leaf), e.g.
   `.../cos/COSStream.java` → `cos`.

Only the **last segment** of the owner is used, then normalized like a name
(prefix strip + token case), so cross-language namespace depth does not matter:
`org.apache.pdfbox.cos` → `cos` and `Pdfbox::Cos` → `cos`. A match found this way
reports `basis: owner`.

This is conservative: ties that cannot be resolved by a unique owner leaf remain
`ambiguous` rather than guessing.

### Inherited / interface members (`match_inherited`)

A Java base-type member (e.g. `PDAbstractContentStream.beginText`) is often
implemented on each Crystal concrete subtype (`PageContentStream`, `FormContentStream`),
so the owner never lines up and the row looks `unmapped_source`. With
`match_inherited: true`, when the strict owner join fails for a **callable**
member, the reconciler falls back to name + signature — but only when the
canonical member is spread across **≥2 distinct target owners** (the
interface/inherited signature) and both signatures agree on arity. Such rows are
reported `ambiguous` with `basis: member` (they are *resolved*, not unmapped, but
we do not guess which concrete owner).

The ≥2-owner requirement is the precision guardrail: a name that exists under a
single unrelated owner (`IndexedColorant.getColor` vs `BlendMode.color`) is a
coincidence and stays `unmapped_source`.

### Prefix stripping is longest-valid

`strip_prefix` uses the **longest** matching prefix that leaves a valid remainder
(non-empty, uppercase- or `_`-leading): `PDFontLike` backs off from `PDF`
(`ontLike`) to `PD` (`FontLike`), while `PDFDocEncoding` keeps `PDF`
(`DocEncoding`). This avoids the old longest-match mangling (`ont_like`).

## Worked example: PDFBox Java → Crystal

`pdfbox/plans/parity_rules.yml`:

```yaml
version: 1
source_language: java
target_language: crystal
match_owner: true

source:
  strip_namespace:
    - "org.apache.pdfbox."
    - "org.apache.fontbox."
    - "org.apache.xmpbox."
    - "com.tom_roush.pdfbox."
  strip_prefix: [COS, PD, FDF, PDF]
  strip_accessor: true

target:
  strip_namespace: ["Pdfbox::", "Pdfbox."]
  strip_prefix: [COS, PD, PDF]
  strip_accessor: false

renames: []
consolidate: []
```

Representative results (11,989 Java entities against the Crystal port):

```
COSBase               -> Base               [matched, owner]
COSDictionary         -> Dictionary         [matched, owner]
COSName               -> Name               [matched, owner]
COSArray              -> Array              [matched, owner]
PDDocumentInformation -> DocumentInformation[matched, owner]
COSStream             -> Cos::Stream        [matched, owner]
COSWriter             -> (ambiguous)        [several *Writer classes]
PDFBoxHeadlessTest    -> (unmapped_source)  [Java-only test]
```

The `COSStream` row is the point of the whole exercise: `Cos::Stream` and
`PDStream` both normalize to `stream`, so name-only matching would silently pick
one. Owner-aware matching uses the `cos` package/module leaf on both sides to
select `Cos::Stream`; ties it cannot resolve (such as the several `*Writer`
classes, whose leaves differ from `pdfwriter`) stay `ambiguous`.

Because owner matching is authoritative, an owner-conflicting name match becomes
`unmapped_source` rather than a silent match. For this corpus that moved the
distribution from **2,549 matched / 4,465 ambiguous / 4,975 unmapped** to
**3,152 matched / 1,524 ambiguous / 7,313 unmapped**: most of the drop in
`ambiguous` is resolved ties, and most of the rise in `unmapped` is generic-name
methods whose owners genuinely disagree (e.g. a `call` on the wrong class) that
were previously false positives.

## Reconciling against the curated ledger (`--format divergences`)

`maps_to` rows become actionable when joined with the curated inventory. The
`divergences` format attaches each inventory row to its mapped status and flags
ledger-vs-structure disagreements:

```bash
"$CHIASMUS/bin/chiasmus-parity" \
  --inventory plans/inventory/java_port_inventory.tsv \
  --source-facts /tmp/java.pl --crystal-facts /tmp/crystal.pl \
  --map-rules plans/parity_rules.yml \
  --format divergences > /tmp/div.tsv
```

```
# falsely_missing=17 falsely_ported=824 total=12429
source_id	kind	inventory_status	map_status	divergence	target_name	target_file	target_owner	basis
fontbox/.../font/Standard14Fonts.java::method::Standard14Fonts.getGlyphList	method	missing	matched	falsely_missing	glyph_list	src/pdfbox/pdmodel/font/standard14_fonts.cr	font	direct
```

- **`falsely_missing`** — the ledger says `missing`, but a Crystal counterpart
  reconciles structurally. These are the highest-signal rows: in the PDFBox run
  they collapsed from 804 (name-only matching) to 56 (owner-aware matching) to
  **17** once members (Java enum constants, Crystal consts/enum members) carried
  their enclosing type in `qualified_name`, which removed leaf-name collisions
  like `XReferenceType.NORMAL` vs `BlendMode.Normal`.
- **`falsely_ported`** — the ledger says `ported`, but no Crystal counterpart
  reconciles structurally. Treat as **needs review**, not authoritative: method
  rows dominate (747 of 825) because the Java extractor emits inconsistent
  qualified names (bare vs owner-qualified) and because a ported method may live
  on a renamed target class, which strict owner matching will not link.

The join feeds `Reconcile.mappings` per fact (matched by exact source name, with
a canonical + owner fallback), so two different source entities that merely
share a canonical key are not conflated.

## Prolog projection (`--format maps-prolog`)

The same reconciliation can be emitted as a self-contained Prolog program so it
can be queried ad-hoc (via `swipl` or the MCP `chiasmus_verify` tool) and folded
into the completion gate:

```bash
"$CHIASMUS/bin/chiasmus-parity" \
  --inventory plans/inventory/java_port_inventory.tsv \
  --source-facts /tmp/java.pl --crystal-facts /tmp/crystal.pl \
  --map-rules plans/parity_rules.yml \
  --format maps-prolog > /tmp/maps.pl

swipl -q -g "consult('/tmp/maps.pl'), forall(falsely_missing(Id), writeln(Id)), halt."
```

Crystal does the lexical work (extract, normalize, canonicalize, owner
resolution) and emits facts; Prolog does the join and recursion:

```prolog
entity(Id, Kind, Name, Owner, Lang).
member(Parent, Child, member).
normalized(Id, Canonical).
rename(From, To).  consolidate(Pattern, Target).  owner_alias(From, To).
maps_to(SourceId, TargetId).           % TargetId is `none` when unmatched
map_status(SourceId, matched|ambiguous|unmapped_source).
inventory_item(Id, Kind, Status, Refs, Notes).
inventory_entity(InventoryId, EntityId).   % bridges ledger ids to fact ids
divergence(InventoryId, Type, TargetName).

maps_to_matched(Id) :- maps_to(Id, Target), Target \= none.
inventory_matched(Id)  :- inventory_entity(Id, Entity), map_status(Entity, matched).
inventory_unmapped(Id) :- inventory_entity(Id, Entity), map_status(Entity, unmapped_source),
                          \+ inventory_matched(Id).
falsely_missing(Id) :- inventory_item(Id, _, missing, _, _), inventory_matched(Id).
falsely_ported(Id)  :- inventory_item(Id, _, ported, _, _),
                       ( \+ inventory_entity(Id, _) ; inventory_unmapped(Id) ).
incomplete(Id)      :- inventory_item(Id, _, Status, _, _),
                       Status \= skipped, Status \= intentional_divergence, \+ complete(Id).
```

On the PDFBox corpus the Prolog queries agree exactly with the Crystal
`--format divergences` counts (`falsely_missing=56`, `falsely_ported=824`) and
add free queries such as `incomplete/1` (10,054) and
`renamed_but_present/2` (2,565). Because `owner_alias/2`, `rename/2`, and
`consolidate/2` are facts, the join can grow transitive rules (e.g. rename
chains) without touching Crystal code.

## Typed surface diff (`--format surfaces`)

Once the walkers emit signatures (P5), the reconciled method pairs can be
compared at the signature level:

```bash
"$CHIASMUS/bin/chiasmus-parity" \
  --source-facts /tmp/java.pl --crystal-facts /tmp/crystal.pl \
  --map-rules plans/parity_rules.yml \
  --format surfaces > /tmp/surfaces.tsv
```

```
# surface_match=2267 surface_mismatch=228 surface_unmodeled=7731 total=10226
source_id	target_id	status	source_arity	target_arity	source_return	target_return	return_match	details
...::method::AdobePDFSchema.setKeywordsProperty	...::method::keywords_property	surface_mismatch	1	0	void	Type::TextType	false	arity 1->0
```

- `surface_match` / `surface_mismatch` compare **arity**, which is reliable
  across languages.
- `return_match` is computed through each side's `type_map` (e.g. Java `void` →
  `nil`, Crystal `Nil` → `nil`; Java `int` → `int`, Crystal `Int32` → `int`) and
  reported for review, but it does **not** by itself fail the status: class-name
  spellings and generics still differ cross-language (`List<COSBase>` vs
  `Array(Cos::Base)`), so return-type equality needs class-name + generic
  normalization before it can be a hard signal.
- `surface_unmodeled` means the source method has no mapped target surface
  (usually a genuinely unported method).

The `maps-prolog` projection emits `surface_status(EntityId, Status)` and adds a
`surface_ok/1` clause to the completion gate:

```prolog
surface_drift(Entity) :- surface_status(Entity, surface_mismatch).
surface_ok(Id) :- \+ (inventory_entity(Id, Entity), surface_drift(Entity)).
complete(Id) :- inventory_item(Id, _, ported, _, _), inventory_matched(Id), surface_ok(Id).
```

On PDFBox this moves **204** ledger-`ported` rows with arity drift out of
`complete` (2,375 -> 2,171), so signature drift shows up in the unified gate
where name-level parity passes.

## Authoring workflow (add rules incrementally)

Start minimal, then let the output tell you what to add:

1. **Run with an empty rule set.** Everything is `matched` by exact canonical
   key or reported `unmapped_source`.
2. **Add `strip_prefix`** for the language's class-prefix conventions until the
   obvious family pairs (`COSBase`/`Base`) collapse. Longest-prefix wins, so
   prefer the most specific prefixes you need.
3. **Turn on `strip_accessor`** if the target uses plain nouns for
   getters/setters. Caveat: getters and setters collapse to the same key; if
   that causes `ambiguous` results you care about, encode exceptions as
   `renames` instead.
4. **Add `renames`** for entity-level mismatches no generic rule can derive
   (e.g. `DefaultResourceCache` → `ResourceCache`).
5. **Add `consolidate`** for many-to-one collapses (operator classes → a single
   dispatch method; `PDXObject` hierarchy → one target).
6. Re-run and diff the `ambiguous`/`unmapped_source` counts each time.

### Choosing prefixes safely

Prefix stripping all sides symmetrically is what makes matches work, but
aggressive prefixes can over-collapse (`PDF` turns `PDFAExtensionSchema` into
`a_extension_schema`). If you see surprising `matched` rows, prefer a longer,
more specific prefix or an explicit `rename`.

## Limitations and next steps

- **Keys are simple-name based.** Version one matches on the normalized simple
  name plus kind compatibility. Owner/namespace-aware keys (so `cos::Stream`
  never collides with `debugger::Stream` without needing ambiguity reporting)
  are the next refinement; until then, `ambiguous` is the correct, visible
  signal.
- **Kind compatibility is coarser than types.** Classes may map to modules or
  structs; there is no signature-level comparison yet (see
  `chiasmus.cr/plans/port_dom.md` for the typed-surface extension).
- **This is structural, not behavioral.** A `matched` row means the entity
  exists and was reconciled by identity, not that its behavior is ported.
  Behavioral parity remains the job of the ported test suites.
