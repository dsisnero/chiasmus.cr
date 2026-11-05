# Vendor Update: Chiasmus `e3e8aa5` (0.1.40)

## Scope and evidence

The vendor submodule advanced from `1ba3cba` (upstream 0.1.37) to `e3e8aa5`
(upstream 0.1.40, 2026-10-18).

The real delta is small. The submodule sits on a locally rewritten branch
(`recovered-pin`), so ancestry is not shared with upstream and
`git rev-list --count 1ba3cba..e3e8aa5` reports 221 commits that are mostly
replayed history. Compare trees instead:

```bash
git -C vendor/chiasmus diff --stat 1ba3cba e3e8aa5
# 5 files changed, 100 insertions(+), 9 deletions(-)
```

| Upstream change | Files | Crystal disposition |
|---|---|---|
| `chiasmus_craft` refuses to store a template when the solver reports an `error` for its `test=true` example; `sat`, `unsat`, `unknown`, and a Prolog query without answers still store (upstream `a229309`). | `src/skills/craft.ts`, `tests/craft.test.ts` | Ported in P79. |
| Tool description and `test` schema property describe the refusal. | `src/mcp-server.ts`, `README.md` | Ported in P79. |
| Version bump 0.1.37 → 0.1.38 → 0.1.39 → 0.1.40. | `package.json` | No Crystal action; shard version is independent. |

Already present at `1ba3cba` despite appearing in the 221-commit log: the
`chiasmus_learn` retirement, `addLearned` → `addTemplate` rename and
promotion-column removal, mermaid linear-time parsing, solver child-process
isolation and limits, the `chiasmus-http` entry point, the graph child-process
pool, and the earlier craft fixes.

## Compatibility contract

1. A crafted template whose `test=true` example makes the solver return
   `status: "error"` is not stored.
2. The result is `{created: false, tested: true, testResult: "error", errors:
   ["Example test failed, so the template was not stored: <solver message>"]}`.
3. A solver or session exception produces `testResult: "error: <message>"` and
   the same single refusal error, also without storing.
4. `unsat`, `unknown`, and a Prolog query with no answers store the template
   and report their normal `testResult`.
5. Because nothing is stored, the refused name stays available for a corrected
   template.

## Pre-existing inventory drift

The curated inventory was last reconciled at `55d43881` (upstream
v0.1.27–v0.1.28), so strict checks fail both before and after this bump:

```text
check_port_inventory.sh  -> 213 source items missing from inventory
check_test_parity.sh     -> 426 test items missing from the generated manifest
```

`src/skills/craft.ts` is already fully ledgered (no missing craft rows), so this
bump adds no curated source rows. Refreshing the generated manifests and
curating the 213 newer source declarations remains the inventory-reconciliation
next-up item rather than part of this vendor update.

## Verification

- `crystal spec spec/chiasmus/skills/craft_spec.cr` — 17 examples, 0 failures.
- `crystal spec spec/mcp_server/tools/craft_spec.cr spec/chiasmus/skills/` —
  84 examples, 0 failures.
- `make lint` and `make test` after the port (see the P79 row in
  `plans/parity.md` for the recorded counts).
