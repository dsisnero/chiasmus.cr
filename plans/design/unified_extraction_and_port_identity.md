# Unified extraction, PortDOM identity, and caching plan

## Goal and boundaries

Make one source parse produce enough structured, provenance-bearing information for
both Chiasmus analysis and cross-language Crystal parity. Keep the existing
`chiasmus-discover` TSV, `chiasmus-facts` Prolog, `chiasmus-parity` reports, and
curated `plans/inventory/*_port_inventory.tsv` usable during migration. This is
an analysis CodeDOM inspired by Kiota, **not** a source generator or a promise
that equivalent declarations have the same spelling or shape in every language.

The upstream `vendor/chiasmus` remains the behavioral source of truth for
Chiasmus. Parity-specific metadata may extend that behavior without changing
the meaning of upstream facts.

## What exists now, and why it is insufficient

| Path | Current useful data | Gap to close |
| --- | --- | --- |
| `Discovery::Pipeline` and query extractors | Broad language coverage, parser predicates, `file::kind::name` inventory IDs | Separate tree-sitter parse from graph extraction; auxiliary `definition.*` records can duplicate declarations; some language concepts (Go grouped `const`, method receiver) are incomplete. |
| `Graph::Extractor` and walkers | Definitions, calls, imports, exports, containment, file type information; bounded per-file work | Walkers and discovery do not share a per-file result. `DefinesFact` has only seven broad kinds plus optional signature/qualified name; typed structure is often lost. |
| Java walker | Class/interface/enum/record and method extraction, method signature, enum qualified members, containment | Good starting example, but ownership, fields, modifiers, annotations, inheritance, constructors, overload identity, and source provenance do not all survive as first-class typed surface fields. The Java discovery extractor separately emits method-like auxiliary nodes. |
| `IR::SemanticGraph` and `PortDom` | Ordered refiners; type, method, and property surface records; signature parsing | Current `PortDom.build` mostly infers from strings and leaves many fields at defaults. `IR::Lowering.symbol_id` includes file, kind, and qualified name; it is a local graph key, **not** a cross-language identity. This corrects the contrary assertion in `plans/port_dom.md` §1. |
| `GraphCache` | SQLite WAL per-file `CodeGraph` and named snapshots | Discovery and typed IR cannot reuse its payload. Version `4` is manually bumped; grammar, parser, adapter, and refiner fingerprints are not individually tracked. A snapshot name is based on options, not the input content set. |
| Parity workflow | Owner-aware matching, rule-based names/kinds, typed surface report, Prolog projection | Four `chiasmus-parity` invocations reload/reconcile the same graphs. The skill does not pass a cache directory to facts, and discovery runs separately. Current joins still depend heavily on names and broad kinds. |

Relevant existing designs are `plans/design/semantic_ir.md` and
`plans/port_dom.md`. This plan completes and reconciles them; it does not add a
third parallel representation.

## Target architecture

```text
files + grammar/adapter versions
    -> shared per-file parse and language adapter
    -> immutable FileExtraction (declarations, references, edges, diagnostics)
    -> ordered language-neutral refiners
    -> SemanticGraph + typed PortDOM
    -> projections: discovery TSV/JSONL, CodeGraph/Prolog, parity, MCP search
                                      -> mapping/PortConceptId + reports
```

`FileExtraction` is the cacheable unit. A language adapter may use AST walking,
queries, or both, but receives the **same parse tree** and attaches query-derived
attributes to the same declaration using node identity/span plus parent context.
It must not emit a second symbol merely because both `method` and
`definition.method` queries match. Parsing is once per changed file per process;
global call resolution, mapping, and report generation happen after per-file
extraction. Keep the parse tree transient, not in the disk cache.

The shared language registry owns extensions, grammar selection, adapter
version, and capabilities. Both CLI scanners and the MCP entry points use it.
Unsupported constructs produce an explicit diagnostic/`unknown` capability,
not an apparently complete empty result. Preserve a selectable regex fallback
where today’s discovery contract requires it, marking its provenance and lower
confidence.

### Typed declaration contract

Each adapter should emit the following when the grammar provides it:

- Declaration: language, namespace/package, owner chain, precise kind
  (including constant, field, constructor, enum/variant, alias, receiver method),
  source path/span, display and qualified names, signature and overload key.
- API surface: ordered parameters (name, type, default, variadic/keyword/block),
  return type, type parameters/bounds, inheritance/implements, visibility,
  static/abstract/mutability, annotations, and documented/deprecated state.
- Relationships: contains, imports/exports, references/calls, inherits or
  implements, with source span and resolution state. Retain unresolved edges
  for the graph-wide resolver rather than guessing a target.
- Provenance: grammar/parser and adapter versions, AST node type, extraction
  method, confidence, and whether a field is absent, unknown, or explicitly
  empty. Avoid interpreting `nil` as “public,” “mutable,” or “no base types.”

Extend `SymbolKind` and the serialized graph compatibly, while keeping existing
Prolog predicates and TSV kinds as a versioned projection. Typed `PortDom`
should be populated from adapter fields first; parse signature text only for
legacy cache/fixture input. Refiner passes may normalize conventions but must
preserve the original spelling/type and their provenance.

### Three identities, not one overloaded string

1. **Occurrence ID** identifies a syntax occurrence for diagnostics: repo-local
   path + span + AST role. It may change when lines move.
2. **Declaration ID** identifies a declaration within one source universe:
   language/module or package/owner chain/precise kind/name/overload key,
   with a disambiguator for duplicate or partial declarations. It is independent
   of the checkout’s absolute path; source locations are attributes. This is
   the stable key for local graph edges and cached projections. Version the
   canonicalization algorithm (for example, `decl:v1`).
3. **Port concept ID** identifies a *verified correspondence* across source and
   target languages (`port:v1:<opaque-id>`). It is assigned after reconciliation
   and persisted with `source_decl_id`, `target_decl_id`, basis, rule/inventory
   provenance, and review status. Matched entities share this ID. Unmatched or
   ambiguous entities do **not** receive a fabricated shared ID. Represent
   one-to-many or many-to-one ports as mapping groups/edges, not by merging
   source declarations.

Explicit rule/ledger mappings have priority; then use owner, precise kind,
normalized name, and typed signature to propose candidates. Never silently
turn an ambiguous proposal into a match. Renames or moves retain continuity
through explicit alias/mapping records. Inventory `source_id` remains a legacy
external key with a resolvable alias table, so existing manifests and human
status rows do not have to be rewritten en masse.

## Delivery sequence and gates

### 0. Baseline and fixture matrix

Inventory every registered discovery language against its graph walker and
current declaration/relationship capabilities. Build checked-in fixtures for
Java, Crystal, Go, TypeScript/JavaScript, Rust, and representative remaining
languages. Include overloaded Java methods, constructors/fields/enum members,
Go grouped const/var and receivers, same-named methods under different owners,
generics, visibility, partial definitions, and an intentional many-to-one
port. Capture current TSV, Prolog, parity, MCP, parse count, and timings before
behavior changes. Use real PDFBox/Keyring/Rod samples as validation, not as the
only expected-output oracle.

**Gate:** a capability table and failing tests for the known duplicate/const/
receiver/ownership cases exist; legacy outputs are snapshotted.

### 1. Shared extraction seam, with Java and Crystal first

Introduce `FileExtraction` and a language-adapter interface in the semantic IR
area. Route `Graph::Extractor` and `Discovery::Pipeline` through one coordinator
and parse-tree lifecycle, initially adapting the Java and Crystal walkers and
their discovery queries. Preserve `discover --parser` behavior and existing
output ordering. Reconcile duplicate query captures by AST identity/owner,
not by leaf name. Keep old projection adapters until parity and MCP consumers
have moved. Adapt Go next: distinguish const/var/type declarations from their
AST nodes, include receiver in owner identity, and merge auxiliary predicates
onto a single method.

**Gate:** one parse per changed file for combined discovery/facts extraction;
no duplicate declarations; old TSV and Prolog outputs remain compatible except
for separately documented corrections. Cached and uncached output is identical.

### 2. Populate the analysis CodeDOM and versioned local IDs

Expand the typed surface and graph relationships above. Have Java, Crystal,
and Go adapters emit structured fields directly; retain signature-text fallback
for older languages. Add occurrence/declaration IDs and a compatibility alias
from existing `file::kind::name`/IR IDs. Keep location changes from changing
declaration IDs unless the declaration is genuinely ambiguous; record those
cases explicitly. Make local ID round-trip through cache, facts, and MCP.

**Gate:** contract tests cover overloads, nested owners, constants, inheritance,
modifiers, calls, and idempotent refiners. IDs remain stable across two worktree
locations and formatting-only line shifts; no collision in the fixture corpus.

### 3. One cache and content-stamped snapshots

Store immutable `FileExtraction` in the existing SQLite WAL infrastructure.
Key it by logical repo identity/path, content digest (Git blob OID when safe;
hash actual bytes for dirty/untracked files), grammar ABI/fingerprint, parser
version, adapter/schema version, and extraction options. For worktree reuse,
separate path-independent parse facts from path-dependent occurrence projection
where practical. Make concurrent callers single-flight on that key; guard
shared caches with mutexes/channels and bound parallel parsing. Invalidate
in-memory entries on every content change, including MCP long-lived processes;
do not require a server restart. Do not cache errors as successful empty graphs.

Cache graph-wide resolution by the ordered set of file extraction hashes and
resolver version. Cache parity reconciliation separately by source/target graph
fingerprints, rule digest, inventory digest, and normalizer version. Attach
content-set fingerprint, schema/tool versions, and cache-hit statistics to each
named snapshot/report. Read snapshots only after validating that fingerprint;
write them atomically. A stale snapshot must fail visibly or recompute, never
silently stand in for current files.

**Gate:** cold/warm/edited-file tests show respectively N/0/1 reparses;
concurrent requests share one extraction; an edited function appears in
discovery, facts, parity, and MCP without restart; snapshot provenance prevents
the stale-diff failure. Cache eviction and schema migration preserve safety.

### 4. Shared parity run and port concept mappings

Add a `chiasmus-parity` bundle mode (or equivalent API) that loads the two
versioned graphs once, reconciles once, and renders maps, surfaces,
maps-Prolog, and divergences from that result. Join inventory rows by source
ID/alias before name fallback. Emit a versioned mapping sidecar with declaration
IDs, PortConceptIds, statuses, basis, and provenance. Keep current TSV/Prolog
columns and predicates as compatibility views, introducing optional new fields
or a new format version. Surface comparison should distinguish unavailable
metadata from an actual mismatch.

**Gate:** all four existing reports are byte-stable where semantics did not
change; deliberately corrected matches are explained; ambiguity remains a
review status; one bundle produces all reports after one reconciliation.

### 5. Release a coherent toolchain before skill rollout

Package `chiasmus-discover`, `chiasmus-facts`, `chiasmus-parity`, the other
parity CLIs, and their grammar libraries as **one platform-specific toolchain**.
Each archive carries a machine-readable manifest with the release tag and source
commit, platform/architecture, build ID shared by every binary, grammar ABI and
fingerprints, extraction/PortDOM/report schema versions, declared capabilities,
and checksums for every included file. Expose the same build ID, schema versions,
and capabilities from a stable `--version --json` or `--capabilities --json`
interface; do not infer compatibility from human-oriented `--help` text. Define
the minimum capability set required by each skill operation, rather than
requiring identical Chiasmus and skill version numbers.

The release workflow must test the **packaged archive**, not only build the
binaries: verify checksums, launch each CLI from the unpacked layout, load its
bundled grammars, and run a small Java→Crystal and Go→Crystal
discover→facts→bundle reconciliation. Publish the archive and checksum/manifest
only after those checks pass. Test the same installer against an untagged local
development bundle without treating that bundle as a published release.

Replace the skill's independent binary searches and all-platform copy script
with one resolver. The skill pins a tested toolchain release; the resolver
selects an explicit whole-toolchain override or the pin, downloads only the
current platform on first use into a versioned user cache, verifies the
manifest/checksums and required capabilities, runs a small self-test, then
atomically activates it. An offline archive or preinstalled directory must use
the same validation path. A local developer build may override the pin only as
a complete, validated toolchain. Never silently combine `discover`, `facts`,
`parity`, and grammars from different build IDs, downgrade a requested strict
parser to regex, or replace a working installation with a failed download.
Report one actionable compatibility error naming the missing capability and
where to obtain a compatible toolchain. Keep the existing environment variables
as transitional aliases, but reject mixed overrides. Record the resolved
toolchain build ID, schema/grammar versions, and archive checksum in generated
manifest metadata so reports are reproducible.

**Gate:** a clean machine can run the pinned skill with one command and no
manual binary copying; warm runs use the verified cached toolchain without a
network request. Corrupted, wrong-platform, missing-grammar, mixed-build, old-
schema, and unavailable-network cases fail clearly without altering the active
installation. Release CI and downstream Java/Go parity smoke tests use exactly
the archive that users install.

### 6. Skill and CLI adoption, then remaining languages

Update `cross-language-crystal-parity` only after new binary contracts are
shipped: use the shared cache directory and bundle path, record binary/schema/
grammar versions and content fingerprints in manifest metadata, and document
the ID alias/mapping workflow. Continue to refresh generated manifests
explicitly; never overwrite the curated `plans/parity.md` or inventory status
columns. Publish version-matched binaries before the skill invokes new flags.

Promote remaining adapters in capability batches: TypeScript/JavaScript/TSX
and Rust, then Python/Ruby/C-family, then the remaining registered languages.
For each, add language-specific semantic fixtures and compare its legacy
discovery/graph projection before switching it to the shared coordinator.
Borrow proven AST patterns from the updated vendors where useful, but treat
vendor code as reference, not an identity or correctness oracle. Do not claim
full coverage merely because a grammar loads.

**Gate per language:** declarations and relationships have explicit capability
coverage; discovery/facts/MCP reuse the same per-file result; parity identities
are collision-tested; `make format`, `make lint`, and `make test` pass. End-to-end
skill runs on Java→Crystal and Go→Crystal repos must yield actionable surface
and mapping gaps, with warm-cache measurements and no stale results.

## Initial implementation slices

1. Tests and coordinator contract, then Java duplicate consolidation and
   typed fields; no CLI behavior switch until fixtures pass.
2. Crystal adapter and Go const/receiver corrections; local ID/alias support.
3. Persistent `FileExtraction` cache and fresh snapshot validation.
4. Parity bundle/PortConceptId sidecar and machine-readable toolchain contract.
5. Package and test one coherent release; add the skill's pinned, verified,
   atomic toolchain resolver before switching its default binary lookup.
6. Remaining language adapters, one capability-reviewed batch at a time.

This ordering avoids another wholesale walker rewrite and gives Chiasmus users
better graph facts as soon as each adapter is upgraded, while parity gains
typed, reviewable correspondences without pretending cross-language syntax is
identical.

## Implementation checkpoint (2026-10-14)

The first compatibility-preserving slice is implemented: both CLI scanners use
a shared language registry; `Graph::Extractor.extract_with_discovery` can run
graph and discovery visitors on one Java/Crystal/Go parse tree; Go discovery
retains method receivers and emits grouped constants; Java graph methods carry
owner-qualified names. Facts snapshots now include input contents and extractor
version in their names. Parity has a single-load `--bundle-dir` mode, and the
parity skill enables the existing per-file facts cache and uses bundle mode
when the binary supports it. Older incompatible bundled parity binaries fail
preflight instead of starting an unusable reconciliation.

The next slice now persists the combined graph-plus-discovery result in the
existing SQLite cache and coalesces concurrent requests for the same file.
Java, Crystal, and Go `discover --cache-dir` and `facts --cache-dir` share it;
cold/warm/edit tests cover stale-result invalidation and CLI output parity.
The skill's discovery wrapper passes the shared cache directory only when its
selected binary advertises the new flag.

The combined payload now also caches a typed `FileExtraction` projection.
The Java adapter preserves precise class/interface/enum/record, method,
constructor, field, constant, and enum-constant kinds, with owners, structured
parameters, modifiers, inheritance text, AST provenance, and versioned local
declaration/occurrence IDs. Tests cover overload identity, movement, interface
implicit modifiers, and warm reuse across checkout roots. The Go adapter now
preserves grouped constants/types, variables, struct fields, functions,
receiver-owned methods, parameters, and local IDs. The Crystal adapter now
preserves module/class/struct/enum/alias kinds, constants, enum members,
fields, typed methods, visibility, and local IDs. Initializer-only fields are
included while explicit typed fields take precedence over duplicate writes;
macro-generated constants are marked as inferred provenance.

This is **not** completion of the target architecture: the typed result is not
yet a full PortDOM, declaration IDs are source-language-local rather than
cross-language PortConceptIds, and graph-wide resolution/parity caches, MCP
consumption, and remaining language adapters are still to be implemented.
The bundle now emits a versioned PortConceptId sidecar for unique matches
authorized by explicit rename rules. IDs are stable across checkout/path
movement; ambiguous, direct, consolidated, and duplicate correspondences are
left without shared IDs. Existing TSV/Prolog views and the curated inventory
ledger are unchanged. The parity CLI can now consume typed per-file JSONL
results and join declaration IDs by exact legacy alias, retaining local
`decl:v1` IDs without changing the `port:v1` decision. Missing, duplicate, or
wrong-language aliases remain unjoined. `chiasmus-facts --declarations-out`
now exports those typed per-file results from its existing bounded graph
extraction pass; tests cover one parse, cold/warm/edit cache behavior, and an
end-to-end Java-to-Crystal parity join. The next slice is to teach the
cross-language parity wrapper to pass those sidecars through when compatible
toolchain binaries advertise both flags.
