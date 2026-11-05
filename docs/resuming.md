# Resuming Work

This is the first thing to read in a new session. It takes a few minutes to get
back to a known-good state.

## 1. Read where we are

- [`../plans/parity.md`](../plans/parity.md) — start at the **Where we are**
  block. It names the current focus, the ordered "Next up" list, gate results,
  and any scoping notes or gotchas. Do not re-derive state from git history.
- [`../plans/inventory/typescript_port_inventory.tsv`](../plans/inventory/typescript_port_inventory.tsv)
  — the per-symbol ledger (status + `crystal_refs`). Use it to see what is left
  inside the current chunk:

  ```bash
  tail -n +2 plans/inventory/typescript_port_inventory.tsv \
    | cut -f3 | sort | uniq -c
  ```

The generated manifests (`typescript_source_parity.tsv`,
`typescript_test_parity.tsv`) are drift snapshots, not the curated ledger. Never
regenerate the curated ledger over existing statuses and refs.

## 2. Confirm the working tree

```bash
git log --oneline -10
git status
```

The last commit should be the previous feature, committed atomically. If the
tree is dirty, finish or stash before starting. Untracked notes under
`issues/` are working material, not a baseline change.

## 3. Confirm a clean baseline

```bash
make lint
make test
```

Both must pass before changing anything. `make lint` runs
`crystal tool format --check src spec` followed by `ameba src spec`;
`make test` runs `crystal spec spec/`.

## 4. Pick the next feature

Take the first unchecked item in the **Next up** list in
[`../plans/parity.md`](../plans/parity.md).

For each feature:

1. Read the upstream source under `vendor/chiasmus` and the nearest upstream
   tests.
2. Port the tests first (red → green); never weaken assertions.
3. Satisfy the **Definition of done** in [`../AGENTS.md`](../AGENTS.md) (API,
   tests, gates, inventory rows, `plans/parity.md` status + **Where we are**
   refresh, divergences).
4. Commit atomically using the commit message convention in `AGENTS.md`.

## If the plan is split

`plans/parity.md` currently carries the full history plus the **Where we are**
block. If it is split later, every split file must be linked from
`plans/parity.md`, and `plans/parity.md` must mark each file
complete/in-progress and name the file being worked on plus the next
file/phase to start.

## Environment notes

This checkout lives on an external/exFAT-style volume, so macOS writes
AppleDouble `._*` sidecars next to real files. They are not Crystal source and
are already git-ignored.

- `make format`, `make lint`, and `make test` delete `._*` under `src/` and
  `spec/` first, so a `._foo_spec.cr` sidecar cannot break globbing or test
  discovery.
- If a git command prints
  `non-monotonic index .../._pack-*.idx`, clear the sidecars inside git's
  directories and rerun it:

  ```bash
  find .git -name '._*' -delete
  ```

- `vendor/chiasmus` is a submodule. The pointer in git is authoritative for the
  port; a locally modified submodule checkout is not. Check it with
  `git ls-tree HEAD vendor/chiasmus` rather than trusting the working tree.
