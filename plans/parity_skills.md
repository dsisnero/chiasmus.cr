# Fact-Driven Cross-Language Parity Workflow

## Goal

Use chiasmus's tree-sitter fact extraction to drive **porting between any two
languages we have grammars for** and to **verify when a port is complete** —
primarily porting *to Crystal*, but the design must stay language-agnostic on
both the vendor (source) side and the port (target) side.

```
vendor source ──facts──▶ port plan ──implement──▶ port target ──facts──▶ verify "done"
   (any lang)                                        (mainly Crystal)
```

Concretely: given a vendor codebase (TypeScript, Go, Rust, Python, …) and a
port target (Crystal), we want to (1) extract structural facts from the vendor,
(2) turn those facts into an ordered, scoped port plan, (3) port, and (4) prove
completeness by comparing vendor facts against port-target facts plus the
curated ledger.

That planning layer must answer two separate questions:

- **What is most important to port first?**
  Hubs, bridges, entry-point-reachable code, symbols with large impact radius,
  public/exported symbols, and cohesive clusters.
- **What is safest to work on first?**
  Isolated or weakly connected code, low-impact leaves, dead code, singleton
  communities, and modules with minimal downstream blast radius.

Supported languages = whatever grammars are bundled / in `vendor/grammars/`
(currently: bash, c, c#, c++, crystal, dart, go, java, javascript, kotlin,
perl, php, proto, python, ruby, rust, scala, typescript) + the tree-sitter
generic fallback.

## Whole-Workflow Scope

This plan is not only about the initial planning step.

It covers the full parity lifecycle:

1. **Bootstrap**
   Discover what exists in vendor and target codebases.
2. **Plan**
   Rank what is important, what is safe, and how to slice the work.
3. **Track**
   Record progress in curated ledgers and parity plans.
4. **Implement**
   Port or repair the next smallest behavior-faithful slice.
5. **Verify**
   Check name-level parity, structural parity, and test parity.
6. **Sign off**
   Prove no meaningful reachable work remains except documented divergences.
7. **Maintain**
   Re-run the workflow after vendor updates, new languages, or platform changes.

The core requirement is that the workflow remain useful from day 0 of a port to
parity-maintenance mode after the port is mostly complete.

## Workflow Artifacts

The workflow needs explicit ownership of each artifact so agents know what to
update and when.

### Repo-local config

Parity workflow settings should live in a repo-local config file at
`./.chiasmus/config.yml`.

- the MCP server should create `./.chiasmus/` on startup so repo-local state
  has a stable home
- startup should not create `config.yml` or seed parity settings automatically
  because not every chiasmus repo is a porting repo
- parity work can opt in later by adding a `parity` section to the existing
  config, preserving unrelated keys
- initial parity keys are:

```yaml
parity:
  vendor_src: vendor/chiasmus
  target_src:
    - src
    - spec
  equivalences:
    - source_path: src
      target_path: src/chiasmus
      target_namespace: Chiasmus
```

This gives us one configurable place to normalize source-vs-target roots
without hard-coding vendor or target directory assumptions into planner/parity
logic. The `equivalences` entries also let parity treat an alternate target
directory layout and an extra Crystal/Ruby namespace prefix as the same
porting surface, which is the common case when the target repo nests code under
an additional top-level module such as `Chiasmus`.

### Source-derived artifacts

- vendor facts: layer-A graph facts for the source tree
- target facts: layer-A graph facts for the port tree
- cached `CodeGraph` snapshots in the shared SQLite graph cache
- declaration snapshots from `chiasmus-discover`
- structural ranking/slicing reports from the planner

These are generated or regenerated as needed.

### Curated artifacts

- `plans/parity.md`
- `plans/inventory/<language>_port_inventory.tsv`
- intentional divergence notes
- any stable seed plans promoted from generated planning output

These are edited deliberately and should not be blindly overwritten.

### Verification artifacts

- generated source/test parity manifests
- `parity_facts.pl`
- structural audit reports
- adversarial signoff results

These prove the current state; they are not the planning source of truth.

## Operating Model

The workflow should behave like this:

```text
discover -> facts -> plan -> curate -> implement -> verify -> sign off
                    ^                                   |
                    |-----------------------------------|
```

Meaning:

- facts inform the plan
- the curated ledger informs implementation sequence
- verification feeds back into planning whenever drift or structural gaps are
  discovered

## What The Workflow Must Support

The full workflow should support all of the following, not just initial seeding:

- starting a port with no inventory
- continuing a half-complete port
- deciding what a second agent can safely work on in parallel
- deciding what must be done first because it is structurally central
- tracking intentional divergences explicitly
- identifying dead or unreachable vendor code that can be deferred
- proving parity drift after an upstream refresh
- re-planning when a previous assumption turns out wrong

## Design Goals

1. **Use existing graph facts, not a second planner model.**
   The planner must be a thin layer over `defines`, `calls`, `imports`,
   `contains`, `entry_point`, `reaches`, `dead`, `community`, `hub`, and
   `bridge`.
2. **Stay language-agnostic.**
   Vendor/source and target/port languages must both remain pluggable.
3. **Separate "important" from "safe".**
   A good planner must rank central/high-risk code differently from
   low-dependency/easy-entry code.
4. **Produce branch-sized slices, not just node rankings.**
   Agents need actionable worksets, not a raw top-100 node list.
5. **Fit the existing parity workflow.**
   The planner should seed `plans/parity.md` and the TSV ledger, not replace
   them.
6. **Remain inspectable.**
   Scores and recommendations must explain *why* a symbol/community was ranked,
   not emit opaque weights.
7. **Degrade gracefully.**
   If communities or bridge scores are unavailable, the planner should still
   work from calls/reachability/exports.
8. **Treat planning and tracking as separate responsibilities.**
   Generated scores suggest work; curated ledgers decide accepted scope.
9. **Support multi-agent work partitioning.**
   The workflow should explicitly surface "safe parallel slices" and "central
   integration slices".
10. **Work in parity-maintenance mode.**
   After a port is mostly green, the same workflow should highlight only vendor
   drift, structural regressions, or stale divergences.

## User-Facing Planning Questions

The planning layer should answer these directly:

1. Which code is central enough that porting it first reduces downstream
   uncertainty?
2. Which code is safe to change because few other symbols depend on it?
3. Which symbols are dead or unreachable and can be deferred or skipped?
4. Which symbols belong together as one feature/community-sized slice?
5. Given an entry point, what is the reachable surface that actually matters?
6. Which completed ports are structurally suspicious despite name-level parity?

The tracking layer should answer these directly:

1. What is the next accepted feature slice in `plans/parity.md`?
2. Which inventory rows are in progress, partial, ported, or intentionally
   divergent?
3. What changed after the last vendor refresh?
4. Which slices are safe to hand to another agent in parallel?
5. What remains incomplete after structural verification?

## Two fact layers (this is the crux)

The repo already has **two separate fact worlds**. The graph world is now
backed by both an inspectable Prolog serialization and the shared cached
`CodeGraph` snapshots that planning/parity reuse directly.

### A. Code-graph facts — `Graph::Facts.graph_to_prolog`

Extracted by tree-sitter from *actual source*, for **any** grammar we have:

```prolog
defines(File, Name, Kind, Line, EndLine).
calls(Caller, Callee).
imports(File, Name, Source).
exports(File, Name).
contains(Parent, Child).
entry_point(Name).
% derived rules: reaches/2, reaches/3, path/3, dead/1, caller_of/2, callee_of/2
% optional insights (include_insights): community/2, cohesion/2, hub/2, bridge/2
```

This is the **structural / relationship** layer: dependency order, reachability,
dead code, module cohesion, blast radius. It is now exposed through the
`chiasmus-facts` CLI and is consumed by `chiasmus-plan`,
the installed `cross-language-crystal-parity` skill bundle’s
`plan_with_chiasmus.sh`, and its `check_completion_gate.sh`. This
is the layer that makes chiasmus special and the one our goal hinges on.

Operationally, `chiasmus-facts` now does two things per run:

- emits a human-inspectable Prolog facts file
- saves a named `CodeGraph` snapshot into the shared SQLite cache and embeds a
  `% graph_snapshot ...` header so downstream tools can load the cached graph
  instead of reconstructing it from facts text

### B. Inventory facts — installed parity skill `generate_inventory_facts.rb` → `plans/inventory/parity_facts.pl`

Derived from the *curated TSV ledgers* (not from parsing code):

```prolog
inventory_item(Id, Kind, Status, Refs, Notes).
status(Id, Status).  ported_item(Id).  missing_item(Id).  partial_item(Id).
intentional_divergence(Id, Notes).
source_api(Id, Status, Refs, Notes).  source_test(Id, Status, Refs, Notes).
conversion_rule(From, To, UpstreamKind, CrystalKind, Notes).
```

This is the **bookkeeping / ledger** layer: queryable porting state ("ported
items with no test", "divergences in the LLM subsystem"). It encodes
human-curated mapping decisions, not code structure.

The two layers now meet in the repo-local workflow: planner, parity, and
completion consume the structural graph layer plus curated inventory state. The
remaining doc gap is to keep the external reusable skill bundle aligned with
the repo-local implementation.

## Current tools mapped to the loop

| Stage | Best existing tool | Verdict |
|---|---|---|
| Enumerate "what exists" in vendor | `chiasmus-discover --language <lang>` | declarations only (`defines`), still useful for manifest generation |
| Extract structural graph facts | `chiasmus-facts` | working layer-A facts CLI plus shared SQLite-backed `CodeGraph` snapshots |
| Rank/slice work | `chiasmus-plan` | implemented: `rank`, `safe`, `slice`, `seed-parity`, `track`, `audit`, `refresh` |
| Track / query port state | curated inventory + `chiasmus-plan track` | generated slices plus curated status are now joinable |
| Verify "is X ported, to what, how sure" | `chiasmus-parity` | name/kind matching plus structural columns when source/target facts are available |
| Verify reachable completion | `chiasmus-complete` / `check_completion_gate.sh` | implemented fact-driven `complete` / `incomplete` gate |
| Run both test suites for signoff | `verify_parity_adversarial.sh` | includes completion gate before Crystal and upstream test commands |

**Current ceiling:** the workflow now uses `calls`, `imports`, `contains`,
`entry_point`, reachability, planner-derived slices, and snapshot-backed graph
reuse, but it is still a structural parity workflow, not a semantic proof
system. "Complete" means the reachable ledger is closed with structural checks
and tests, not that the port is mathematically proven behavior-identical.

- `chiasmus-discover` (`src/chiasmus_discover.cr`): vendor declaration
  enumeration → `{path}::{kind}::{name}` TSV. Used by the scripts as the
  tree-sitter backend.
- `chiasmus-parity` (`src/chiasmus/parity.cr`): cross-language name/kind
  matching of a curated inventory row → a target symbol, with confidence +
  `match_status` (`curated_exact|curated_alias|candidate_exact|candidate_alias|
  ambiguous_candidate|curated_ref_only|stale_ref_path|intentional_divergence|
  unmapped`). It consumes a **curated inventory**, not the vendor source.
  It now respects explicit `target_symbol` aliases for deterministic renamed
  ports and preserves `qualified_name` facts through structural checks instead
  of collapsing to simple names. It is part of the repo-local parity workflow
  and is consumed by the completion gate and planner bundle scripts.

## Remaining gaps

1. **The bundle now emits real-repo planning artifacts, but the plan is not
   yet trustworthy.** On July 14, 2026, a clean run of the installed
   `cross-language-crystal-parity` skill’s `plan_with_chiasmus.sh` against this
   repo produced
   `seed.md`, `rank.tsv`, `safe.tsv`, `slices.tsv`, `track.tsv`, and
   `parity.tsv` in `temp/plan-verify-current/`, which proves the shared
   extraction/cache/parity path is usable. However, the generated plan still
   has unsound recommendations:
   - `rank.tsv` over-prioritizes internal helpers such as
     `collapseSignature`, `cljSymName`, and `resolveTargets`
   - `safe.tsv` misclassifies many exported interfaces/types as
     dead-code cleanup candidates
   - `slices.tsv` / `track.tsv` generate a giant `cleanup:dead-code` slice
     that is not branch-sized or actionable
2. **Completion-stage finalization still needs a real-repo fix.** The planner
   bundle now preserves nonzero `completion_status.tsv` output in focused
   specs, but the live repo run still failed to finalize
   `completion_status.tsv` / `completion_incomplete.tsv` before interruption.
   That needs its own end-to-end red-green follow-up.
3. **Verification is still structural, not semantic.** The current checks catch
   missing symbols, import/call/containment drift, and completion gaps, but
   they do not prove full behavioral equivalence.
4. **The external parity skill bundle still lags the repo-local workflow.**
   Repo scripts and CLIs are ahead of the reusable skill documentation and need
   to stay synchronized.

## Plan To Reach Trustworthy Generated Plans

Yes, this is possible.

The hard part is no longer graph extraction. We already have the needed
primitives:

- shared SQLite + `CodeGraph` snapshot caching
- source and target fact extraction through the same graph path
- structural parity reports tied to curated inventory rows
- planner outputs for `rank`, `safe`, `slice`, `seed-parity`, and `track`

What is missing is a stronger contract for **planner correctness**. The next
work should treat plan quality as a separately testable layer above extraction.

### Milestone G0 — Lock the acceptance contract

Write down what "correct plan" means before adjusting heuristics.

Acceptance criteria:

- the top-ranked work should prefer reachable, incomplete, parity-relevant
  symbols over private helper centrality
- `safe` should not label exported API surface or mapped parity rows as
  cleanup solely because they are low-degree or type-only
- `slice` and `track` should produce branch-sized worksets, not one giant
  cleanup bucket
- the planner bundle should finish and materialize completion artifacts on the
  real repo

### Milestone G1 — Build deterministic planner fixtures

Add red-green fixture specs for the planner inputs and outputs, not just file
existence.

Needed fixture cases:

- helper-heavy source graphs where internal utilities have high degree but are
  not the next porting priority
- type/interface-only modules that are exported and mapped, so `safe` must not
  recommend cleanup
- namespace/path-equivalent source vs target layouts
- intentionally divergent rows that should not dominate the plan
- test-only source rows that should not be mistaken for core implementation

Acceptance:

- focused specs assert exact or tightly bounded `rank`, `safe`, `slice`, and
  `track` outputs for each fixture
- golden outputs live in isolated spec files and use the same file naming
  conventions as the rest of the repo

### Milestone G2 — Make planner scoring parity-aware

Update planner heuristics so planning uses curated parity state, not only raw
graph centrality.

Required changes:

- up-rank reachable `unmapped`, `candidate_*`, and structurally drifting
  `ported` rows
- down-rank symbols already covered by confident parity matches unless they are
  part of an accepted incomplete slice
- heavily down-rank internal helper nodes when their owning exported feature
  row is the real actionable unit
- prevent exported interfaces/types from becoming `cleanup` unless they are
  both unreachable and unmapped

Acceptance:

- the top section of `rank.tsv` on this repo is dominated by actionable parity
  work, not helper trivia
- `safe.tsv` stops recommending cleanup for mapped exported API rows such as
  `AnalysisRequest`, `CodeGraph`, and similar inventory-backed surface

### Milestone G3 — Make slices branch-sized and reviewable

Split cleanup and feature groups into bounded units that a porting agent can
actually execute.

Required changes:

- cap slice size
- split oversized cleanup slices by file, directory, or community
- prefer source-file or feature-root naming in slice ids when that is more
  informative than raw community numbers
- keep `parallel_safe` meaningful by avoiding giant mixed-purpose groups

Acceptance:

- no generated slice contains hundreds of heterogeneous members
- `seed.md` reads like a reviewable draft for `plans/parity.md`, not a dump of
  graph communities

### Milestone G4 — Finish the live bundle and promote a smoke gate

Treat the real repo run as its own acceptance test.

Required changes:

- fix the completion-stage finalization issue in
  the installed `cross-language-crystal-parity` skill’s
  `plan_with_chiasmus.sh` or the underlying completion command path
- rerun from a clean `temp/` directory against this repo
- inspect the generated artifacts for both existence and plan quality

Acceptance:

- `completion_status.tsv` and `completion_incomplete.tsv` are finalized in the
  live run
- `seed.md`, `rank.tsv`, `safe.tsv`, `slices.tsv`, and `track.tsv` are
  materially useful to a human reviewer
- the resulting plan can be used to seed or refresh `plans/parity.md` with
  minimal manual correction

## Proposed CLI Surface

We should add a dedicated planning CLI instead of overloading `chiasmus-facts`
or forcing planning into the existing parity matcher.

Current binary:

```text
chiasmus-plan
```

Recommended subcommands:

### `rank`

Rank symbols or files by importance.

Example:

```bash
chiasmus-plan rank \
  --language typescript \
  --dir vendor/chiasmus/src \
  --entry-point main \
  --format table
```

Primary use:

- identify hubs/bridges/high-impact symbols first

### `safe`

Rank symbols or files by safety/ease of change.

Example:

```bash
chiasmus-plan safe \
  --language crystal \
  --dir src \
  --format json
```

Primary use:

- find low-dependency leaves, dead code, singleton islands, and low-blast-radius
  entry tasks

### `slice`

Group symbols into branch-sized worksets.

Example:

```bash
chiasmus-plan slice \
  --language typescript \
  --dir vendor/chiasmus/src \
  --entry-point main \
  --top 10
```

Primary use:

- produce communities / contained symbol groups that can become feature entries
  in `plans/parity.md`

### `seed-parity`

Convert vendor facts into an initial parity plan/seed report.

Example:

```bash
chiasmus-plan seed-parity \
  --language typescript \
  --dir vendor/chiasmus/src \
  --entry-point main \
  --out plans/seed_parity.md
```

Primary use:

- create an initial prioritized roadmap before manual curation

### `audit`

Explain why a symbol or file is ranked as important or safe.

Example:

```bash
chiasmus-plan audit \
  --language typescript \
  --dir vendor/chiasmus/src \
  --symbol loadConfig
```

Primary use:

- make the planner inspectable and debuggable

### `track`

Summarize accepted parity work from curated artifacts plus generated facts.

Example:

```bash
chiasmus-plan track \
  --inventory plans/inventory/typescript_port_inventory.tsv \
  --parity-plan plans/parity.md \
  --facts vendor.pl
```

Primary use:

- show accepted slices, in-progress work, blocked work, and candidate parallel
  worksets

### `refresh`

Recompute planning recommendations after vendor changes or verification drift.

Example:

```bash
chiasmus-plan refresh \
  --language typescript \
  --dir vendor/chiasmus/src \
  --entry-point main
```

Primary use:

- parity-maintenance mode after upstream refreshes

## Output Model

The planner should support at least:

- `table`
- `json`
- `tsv`
- `markdown`

Each row should carry explainable fields such as:

- `symbol`
- `file`
- `kind`
- `reachable_from_entry`
- `dead_code`
- `caller_count`
- `callee_count`
- `impact_count`
- `hub_degree`
- `bridge_score`
- `community_id`
- `community_size`
- `contains_count`
- `priority_score`
- `safety_score`
- `reasons`
- `recommendation`

Planner/slice reports should also carry:

- `slice_id`
- `slice_kind`
- `accepted_status`
- `inventory_refs`
- `parallel_safe`
- `blocked_by`
- `depends_on_slices`

## Tracking Model

Planning output and tracking state are not the same thing.

### Generated planning state

Computed from facts:

- importance
- safety
- slice candidates
- structural drift
- reachability

### Curated tracking state

Accepted by humans/agents:

- feature order in `plans/parity.md`
- row status in `*_port_inventory.tsv`
- intentional divergence rationale
- whether a slice is actively in progress

### Rule

Generated planning may propose work, but curated tracking decides committed
scope.

## Recommended Workflow

### Phase 0 — Bootstrap

Use:

- `chiasmus-discover`
- `chiasmus-facts`
- parity manifest generation/check scripts

Outcome:

- declaration view
- structural graph facts
- initial manifest coverage

### Phase 1 — Plan

Use:

- `chiasmus-plan rank`
- `chiasmus-plan safe`
- `chiasmus-plan slice`
- `chiasmus-plan seed-parity`

Outcome:

- proposed feature order
- proposed safe parallel work
- proposed cleanup/defer candidates

### Phase 2 — Curate

Promote the generated plan into:

- `plans/parity.md`
- `plans/inventory/<language>_port_inventory.tsv`

Outcome:

- accepted work order
- explicit divergences
- clear branch-sized slices

### Phase 3 — Implement

Use the normal parity discipline:

1. port the next failing or missing parity slice
2. make the smallest change that turns it green
3. update the curated ledger
4. repeat

### Phase 4 — Verify

Run:

- name-level parity checks
- structural parity checks
- source/test drift checks
- repository quality gates

### Phase 5 — Signoff

Use the merged facts to answer:

- what remains incomplete?
- what remains intentionally divergent?
- is anything structurally suspicious despite passing tests?

### Phase 6 — Maintain

After upstream refreshes:

1. regenerate source/test manifests
2. refresh graph facts
3. rerun planner ranking/slicing
4. compare against current curated plan
5. add or reorder slices only where drift justifies it

## Ranking Model

The planner should compute two distinct composite scores.

### Importance score

Signals that should increase importance:

- reachable from one or more entry points
- exported/public symbol
- high `impact_count`
- high in-degree / many transitive callers
- `hub_degree`
- `bridge_score`
- membership in a dense/high-cohesion community
- parent container with many contained symbols

Suggested interpretation:

- **high importance** = port or review early
- **medium importance** = follow once enabling nodes are done
- **low importance** = defer unless pulled in by a feature/community

### Safety score

Signals that should increase safety:

- unreachable / `dead_code`
- low `impact_count`
- low caller count
- not a hub
- not a bridge
- singleton community or tiny weakly connected component
- leaf node or near-leaf node

Suggested interpretation:

- **high safety** = good first task for parallel porting or low-risk refactoring
- **low safety** = central integration point; do later or with more review

### Important distinction

"No dependencies" is not the right safety test by itself.

What users usually want is one of:

- **few downstream dependents**: safe to change
- **few prerequisites**: easy to port
- **unreachable/dead**: safe to defer or skip

The planner should expose these separately instead of collapsing them.

## Slicing Model

Node ranking is not enough. We need work slices.

The slicing heuristic should combine:

- `community` membership for cohesive clusters
- `contains` for parent/child structural grouping
- `entry_point` reachability to ignore irrelevant subgraphs
- `dead` to exclude deferred symbols
- optional maximum slice size to avoid huge "everything in community 0" buckets

Recommended slice types:

- **foundational slice**: hubs/bridges/high fan-in nodes
- **safe slice**: weakly connected leaves or singleton communities
- **feature slice**: reachable community rooted at an exported/public symbol
- **cleanup slice**: dead code or unreachable nodes

The tracker should then mark each slice as one of:

- `proposed`
- `accepted`
- `in_progress`
- `blocked`
- `complete`
- `deferred`
- `intentional_divergence`

## How This Fits The Existing Artifacts

The planner should produce outputs that feed, not replace:

- `plans/parity.md`
- `plans/inventory/<language>_port_inventory.tsv`

Recommended workflow:

1. `chiasmus-facts` extracts the vendor graph facts.
2. The emitted facts file carries `% graph_snapshot ...` metadata so downstream
   tools can reload the cached `CodeGraph` from the shared SQLite cache instead
   of reparsing the Prolog dump.
3. `chiasmus-plan rank/safe/slice` produces human-reviewable planning output.
4. `chiasmus-plan seed-parity` drafts a Markdown roadmap and optional TSV seed.
5. Human/agent curates `plans/parity.md`.
6. Porting proceeds with the normal parity workflow.
7. `chiasmus-parity` + structural checks verify completion.

## How To Partition Work Across Agents

The workflow should explicitly support safe parallelism.

Good parallel slices:

- singleton communities
- low-impact leaves
- dead/unreachable cleanup
- disconnected or weakly connected subgraphs

Poor parallel slices:

- hubs
- bridges
- high fan-in integration symbols
- slices blocked by shared foundational abstractions

The planner should label slices with:

- `parallel_safe`
- `foundation_first`
- `integration_risk`

## Staged plan (the bridge)

### Step 1 — `chiasmus-facts` CLI

Thin CLI wrapping `Graph::Extractor` + `Graph::Facts.graph_to_prolog`, generic
over `--language`. Emits the layer-A Prolog for any dir/language.

```
chiasmus-facts --language typescript --dir vendor/chiasmus/src > vendor.pl
chiasmus-facts --language crystal    --dir src                 > port.pl
```

Reuses `Graph::Extractor.extract_graph` and the shared `GraphCache` for
per-file reuse, then persists a named `CodeGraph` snapshot and emits a facts
header pointing at that cached snapshot. Options: `--entry-point NAME`
(repeatable), `--insights`, `--cache-dir`, `--repo-key`, `--cache-max-bytes`.

### Step 2 — Plan from vendor facts

Convert vendor layer-A facts → seed `<language>_port_inventory.tsv`:
dependency-order (`reaches`/`callee_of`), drop `dead/1`, scope to
reachable-from-`entry_point`, group by `community`/`contains` into
branch-sized features for `plans/parity.md`.

#### Step 2A — Symbol scoring

Build a planner layer on top of:

- `Graph::Analyses`
- `Graph::Insights`
- `Graph::CommunityDetection`
- `Graph::Facts`

Compute:

- importance score
- safety score
- rationale strings for each score

#### Step 2B — Slice generation

Use `community` + `contains` + reachability to generate worksets:

- foundational
- safe
- feature
- cleanup

Each workset should have:

- title
- member symbols
- key rationale
- estimated dependency risk
- recommended sequence

#### Step 2C — Seed `plans/parity.md`

Generate a Markdown draft that humans can curate.

The draft should not directly overwrite curated ledgers without review.
Safer outputs:

- `plans/seed_parity.md`
- `plans/seed_safe_work.md`
- `plans/seed_foundational_work.md`

### Step 2D — Tracking integration

Teach the planner to read:

- `plans/parity.md`
- `plans/inventory/<language>_port_inventory.tsv`

and emit a merged view:

- proposed vs accepted slices
- accepted but structurally suspicious slices
- safe parallel work that is still unclaimed

### Step 3 — Structural verification

Extend `chiasmus-parity` (or a sibling) to compare normalized `calls`/`contains`
of each mapped pair → add `structural_match` / `structural_drift` alongside the
existing name-level status. Reuse `Parity::Naming` for cross-language name
normalization, applied to **both** fact sets.

### Step 4 — Wire into the skill + unified "done" gate

Merge facts into one Prolog program — vendor-A (prefixed) + port-A (prefixed) +
inventory-B — and ship the completion gate as a query:

```prolog
complete(Id) :-
    reachable_from_entry(Id),
    ported_item(Id),
    target_match(Id, _),
    structural_ok(Id),
    tested(Id).

incomplete(Id) :-
    reachable_from_entry(Id),
    \+ complete(Id),
    \+ intentional_divergence(Id, _),
    \+ skipped(Id).
```

`?- findall(Id, incomplete(Id), Todo).` = the live "what's left to port" list.
`?- \+ incomplete(_).` = the port is provably complete.

Then update the `cross-language-crystal-parity` skill to drive
`chiasmus-facts` + the structural check instead of (or alongside) the Ruby
`parity_inventory_lib.rb` matching layer.

## Implementation Plan

### Phase P1 — Planner report over existing graph analyses

Deliver:

- `chiasmus-plan rank`
- `chiasmus-plan safe`
- table/json output

Reuse:

- `Graph::Analyses.run_analysis_from_graph`
- `Insights.detect_hubs`
- `Insights.detect_bridges`
- `CommunityDetection.detect`
- existing dead-code and impact analysis

Acceptance:

- ranking works on vendor TypeScript and Crystal source trees
- output explains score reasons
- no parity ledger changes required for this phase

### Phase P2 — Slice generation

Deliver:

- `chiasmus-plan slice`
- feature/foundational/safe/cleanup grouping

Acceptance:

- planner can emit branch-sized groups instead of single symbols
- groups are deterministic across runs

### Phase P3 — Parity seed output

Deliver:

- `chiasmus-plan seed-parity`
- Markdown draft suitable for `plans/parity.md` curation

Acceptance:

- generated plan is reviewable by a human
- does not overwrite curated inventory by default

### Phase P3.5 — Tracking report

Deliver:

- `chiasmus-plan track`
- merged generated+curated status view

Acceptance:

- shows proposed, accepted, in-progress, blocked, and complete slices
- highlights parallel-safe remaining slices

### Phase P4 — Structural parity audit

Deliver:

- `chiasmus-plan audit`
- structural drift explanations per mapped symbol

Acceptance:

- catches at least obvious call-shape drift where name-level parity passes

### Phase P5 — Skill wiring

Deliver:

- `cross-language-crystal-parity` workflow consumes the planning layer

Acceptance:

- the skill can propose "important first" and "safe first" slices before code
  changes start
- the skill can also report accepted progress and remaining work after changes

### Phase P6 — Maintenance mode

Deliver:

- `chiasmus-plan refresh`
- vendor-refresh-aware re-planning

Acceptance:

- after an upstream refresh, the workflow highlights only changed or newly risky
  slices instead of rebuilding the whole plan from scratch

## Non-Goals

- Replacing the curated ledger with a fully generated one.
- Pretending centrality metrics alone prove semantic importance.
- Hard-coding Crystal as the only target language.
- Creating a black-box ML prioritizer.
- Treating planner output as automatically correct without curation.
- Requiring structural parity to be perfect before any implementation work can
  start.

## Status

- [x] Step 1: `chiasmus-facts` CLI — `src/chiasmus_facts.cr`, wired into
      `shard.yml` + `Makefile` (built with `-Dpreview_mt -Dexecution_context`
      like the server graph engine). Verified: vendor TypeScript
      (`vendor/chiasmus/src`, 53 files → 530 defines / 1416 calls / 473 imports)
      and Crystal (`src/chiasmus`, 129 files → 2037 / 7117 / 1478). Facts are
      queryable Prolog: `callee_of('loadConfig', X)` and `dead/1` (found 6
      unused vendor functions) both resolve under swipl. Facts emission now
      also persists named `CodeGraph` snapshots into the shared SQLite cache
      and advertises them via `% graph_snapshot ...` headers so plan/parity do
      not need to regenerate or reconstruct the same graph.
- [x] Step 2: vendor-facts → port-plan seeder — implemented across `src/chiasmus/plan.cr` / `src/chiasmus_plan.cr` as `rank`, `safe`, `slice`, `seed-parity`, and `track`; covered by `spec/chiasmus/plan_spec.cr`
- [x] Step 3: structural parity (`structural_match`/`structural_drift`) —
      implemented in `src/chiasmus/parity.cr` with per-row structural audit
      columns exposed by `chiasmus-parity`; currently checks direct-call drift,
      defining-file import drift, containment drift, export-visibility drift,
      entry-point drift, and missing-symbol drift against source/target fact
      graphs, covered by
      `spec/chiasmus/parity_spec.cr`
- [x] Step 4: skill wiring + unified `complete/1` gate — the completion-facts half now exists in `src/chiasmus/parity.cr` via `chiasmus-parity --format completion-facts`, with `complete/1` and `incomplete/1` query coverage in `spec/chiasmus/parity_spec.cr`; `src/chiasmus/complete.cr` and `src/chiasmus_complete.cr` now expose a first-class `chiasmus-complete` gate with `status|complete|incomplete` queries and nonzero status output while reachable incomplete work remains; the installed `cross-language-crystal-parity` skill bundle’s `check_completion_gate.sh` supports pass-through `--query/--format` usage, its `plan_with_chiasmus.sh` materializes a reusable planner bundle (`rank`, `safe`, `slice`, `seed-parity`, `track`, parity TSV, parity summary, completion status, incomplete rows), and its `summarize_parity_report.rb` turns raw parity TSV output into actionable drift counts
- [x] P1: planner ranking CLI (`rank` / `safe`) — implemented in
      `src/chiasmus/plan.cr` with TSV/JSON output via `src/chiasmus_plan.cr`;
      covered by `spec/chiasmus/plan_spec.cr`
- [x] P2: planner slice CLI (`slice`) — implemented with deterministic
      foundational/feature/safe/cleanup grouping and CLI coverage in
      `spec/chiasmus/plan_spec.cr`
- [x] P3: seed plan generation (`seed-parity`) — implemented as a Markdown
      roadmap draft generator in `src/chiasmus/plan.cr`, exposed via
      `chiasmus-plan seed-parity` with stdout and `--out FILE` support; covered
      by `spec/chiasmus/plan_spec.cr`
- [x] P3.5: tracking/status CLI (`track`) — implemented as a generated-slice
      plus curated-status merge in `src/chiasmus/plan.cr`, exposed via
      `chiasmus-plan track` with TSV/JSON output and parity-plan status parsing;
      covered by `spec/chiasmus/plan_spec.cr`
- [x] P4: planner audit/explanation surface (`audit`) — implemented as a
      symbol-level explanation view in `src/chiasmus/plan.cr`, exposed via
      `chiasmus-plan audit --symbol NAME` with Markdown/JSON output; covered by
      `spec/chiasmus/plan_spec.cr`
- [x] P6: maintenance refresh CLI (`refresh`) — implemented as a current-vs-
      previous facts diff over generated slices in `src/chiasmus/plan.cr`,
      exposed via `chiasmus-plan refresh --previous-facts FILE` with TSV/JSON
      output; covered by `spec/chiasmus/plan_spec.cr`

## Verification snapshot (2026-07-14)

- The installed `cross-language-crystal-parity` skill’s
  `plan_with_chiasmus.sh` was verified in `temp/` against a minimal
  disposable repo using the real `chiasmus-facts`, `chiasmus-plan`,
  `chiasmus-parity`, and `chiasmus-complete` binaries. After fixing the
  parity/completion CLI wrapper entrypoints, the disposable run completed
  end-to-end and generated non-empty `rank.tsv`, `safe.tsv`, `slices.tsv`,
  `seed.md`, `track.tsv`, `parity.tsv`, `parity_summary.txt`,
  `completion_status.tsv`, and `completion_incomplete.tsv`.
- The same script was then exercised against the real `vendor/chiasmus`
  TypeScript source plus this repo's `src/` Crystal tree, again in `temp/` to
  avoid touching curated planning artifacts. That run produced `source_facts.pl`
  but did not complete `crystal_facts.pl` before interruption, so the
  repo-sized end-to-end workflow is not yet marked proven.
- Focused red-green tests now also verify the snapshot-backed reuse path:
  `spec/chiasmus/facts_cli_spec.cr` proves `chiasmus-facts` emits
  `% graph_snapshot ...` metadata and persists the extracted graph,
  `spec/chiasmus/plan_spec.cr` proves `Plan.load_facts` reloads the cached
  `CodeGraph`, and `spec/chiasmus/parity_spec.cr` proves
  `Parity::Structural.load_facts` does the same while still honoring scoped-call
  and entry-point facts from the emitted file.
- The planning design is therefore validated at the logic level and at the
  disposable-repro level, but operational verification on the full repo still
  depends on stabilizing Crystal fact extraction on the full repo-sized source
  tree.

## Design constraints

- Language-agnostic on both sides; Crystal is the primary port target but never
  hard-coded as the only one.
- Reuse the existing tree-sitter `Graph`/`Discovery` engine — no second parser.
- Keep emitting the skill's TSV/Prolog conventions so existing ledgers and
  `parity_facts.pl` queries keep working.
- Honor the concurrency invariants (see `docs/architecture.md`): long-running
  extraction returns `Channel(T)`; no shared mutable state without sync.
- Planner rankings must be deterministic for the same graph input.
- Every score should be explainable with explicit reasons.
