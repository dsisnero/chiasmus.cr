# Reboot Handoff — 2026-07-29

## Current repository state

- Repository: `/Volumes/extreme_ssd/repos/github.com/dsisnero/chiasmus.cr`
- Branch: `main`, clean after the commits below; it was two commits ahead of
  `origin/main` at the original handoff. The Crystal extractor fix below is
  currently uncommitted (two modified files).
- Latest Chiasmus vendor source-of-truth revision:
  `vendor/chiasmus @ d1f1291e14e8459465d722662eb6bb997c2d648d`
  (upstream `main`).

## Completed this session

1. Removed superseded Chiasmus `refactor` work:
   - Audited `a8284a1`; it copied the Tree-sitter runtime into Chiasmus and
     used a stale path dependency. Current `main` and
     `tree-sitter-manager` supersede it.
   - Reset the `refactor` worktree to `main`, detached it at `4011258`, then
     deleted the `refactor` branch.
   - Preserved that worktree's untracked Node/vendor artifacts in
     `stash@{0}` (`codex: preserve pre-reset refactor worktree artifacts`).
   - Left its dirty `grammars/tree-sitter-python` submodule untouched.

2. Verified the rebuilt Chiasmus MCP server:
   - `chiasmus_review` returned a valid quick plan through the real stdio MCP
     binary and the directly connected `mcp__chiasmus` tool.
   - Graph summary for `src/chiasmus/review.cr`: 1 file, 15 functions,
     47 call edges; cycles and layer violations were empty.
   - Apparent review-plan dead code (`build_plan`,
     `make_authorization_phase`, `make_correctness_phase`) is a single-file
     graph-analysis false positive. All three are live and were verified by
     `all`, `security`, and `correctness` review focus calls.

3. Updated the Chiasmus vendor submodule:
   - Previous: `576ed38`.
   - New upstream `main`: `d1f1291`.
   - Commit: `5ccda57 chore: update Chiasmus vendor to latest main`.

4. Audited the upstream vendor delta and wrote the implementation plan:
   - Upstream feature is opt-in local GGUF embeddings (v0.1.25/v0.1.26).
   - Crystal already has local Ollama support, but lacks the upstream
     `localEmbeddings` config/env contract, local-first resolution,
     in-process local backend, and formalization embedding wiring.
   - Node `node-llama-cpp` packaging is an intentional implementation
     divergence; Crig remains the common Crystal embedding interface.
   - Plan: `plans/vendor_chiasmus_d1f1291.md`.
   - Commit: `2a76c20 docs: plan local embedding parity for vendor update`.

5. Fixed Crystal graph extraction for compile-time macro blocks:
   - `lib/crig/src/crig.cr` uses `{% begin %}` to compute `VERSION`. The
     Crystal Tree-sitter grammar represents that code as `macro_content` and
     `macro_expression`, not as a `const_assign`.
   - Before the fix, the extractor omitted `VERSION` and emitted compile-time
     operations (`read_file`, `lines`, `select`, `first`, `split`, `last`,
     `strip`, and `starts_with?`) as false runtime calls owned by `Crig`.
   - `src/chiasmus/graph/walkers/crystal.cr` now treats `macro_begin` as a
     compile-time boundary. It recovers an immediately interpolated uppercase
     assignment as a variable definition, but does not traverse the
     compile-time expression as runtime code.
   - Added a red-green regression spec in
     `spec/chiasmus/graph/crystal_walker_spec.cr` using the exact Crig
     version-macro pattern. It asserts `Crig`, `VERSION`, their containment,
     and zero runtime calls.
   - Verified the real `lib/crig/src/crig.cr`: definitions
     `Crig, VERSION, UPSTREAM_URL, UPSTREAM_COMMIT, UPSTREAM_SOURCE_PATH`;
     0 calls; 42 imports.
   - Passed: focused Crystal spec (25 examples), format check, and Ameba.

## Pending before updating Crig

Create a Chiasmus graph snapshot of **production Crig sources** before changing
the shard:

- Snapshot name: `crig-pre-update-2026-07-29`
- Intended source set: all `*.cr` files under `lib/crig/src`, excluding
  AppleDouble `._*` files (161 files at handoff).
- Use the default Chiasmus graph cache, then later run
  `chiasmus_graph analysis="diff" against="crig-pre-update-2026-07-29"`
  on the same production source set after the Crig update.

### Snapshot status

No complete named snapshot was confirmed. Do **not** assume one exists.

- The direct session MCP connector stalled on multi-file `lib/crig` calls.
- A fresh `bin/chiasmus` stdio MCP process successfully analyzed the single
  file `lib/crig/src/crig/agent.cr` (70 functions, 11 classes, 222 call edges),
  showing the source itself parses correctly.
- The full 161-file request needs a live MCP connection long enough for the
  extraction and snapshot flush. A subsequent reconnect attempt was manually
  interrupted while still running; no success response was received. The
  snapshot remains unconfirmed.

## First steps after reboot

1. Confirm Chiasmus MCP has reconnected and call `mcp__chiasmus__chiasmus_graph`
   with the 161 absolute production source paths, `analysis: "summary"`, and
   `save_snapshot: "crig-pre-update-2026-07-29"`.
2. Confirm the tool returns success. Optionally issue a small diff/snapshot
   lookup before changing Crig to prove persistence.
3. Only then update the Crig shard. Preserve this baseline name for the
   post-update graph diff.
4. Continue P28 from `plans/vendor_chiasmus_d1f1291.md` only after reviewing
   the Crig update impact.

## Other repositories

- `tree-sitter-manager`: `main` contains `5d8e149` and was one commit ahead
  of its remote at last check. It had only an untracked `.lattice-cache/`.
- `tree-sitter-manager-cli`: recent query/lint cleanup is on local `main`;
  no tracking remote was configured at last check.
