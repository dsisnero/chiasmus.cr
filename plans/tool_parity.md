# Chiasmus MCP Tool Parity Plan

## Summary

All 8 upstream tools are ported to Crystal. The main gap is `chiasmus_graph` spec coverage.

| Tool | Upstream | Crystal | Specs | Status |
|------|:--------:|:-------:|:-----:|:------:|
| `chiasmus_verify` | ✓ | ✓ | ✓ (13) | Complete |
| `chiasmus_skills` | ✓ | ✓ | ✓ (7) | Complete |
| `chiasmus_formalize` | ✓ | ✓ | ✓ (6) | Complete |
| `chiasmus_solve` | ✓ | ✓ | ✓ (4) | Complete |
| `chiasmus_learn` | ✓ | ✓ | ✓ (8) | Complete |
| `chiasmus_lint` | ✓ | ✓ | ✓ (10) | Complete |
| `chiasmus_graph` | ✓ | ✓ | ✓ (26) | Complete |
| `chiasmus_craft` | ✓ | ✓ | ✓ (2) | Complete |
| `chiasmus_crig` | — | ✓ | ✓ (2) | Crystal-only |

---

## Phase Plan

### T0: Improve Existing Under-Speced Tools — Implemented

#### `chiasmus_graph` — spec written

- `[x]` `spec/mcp_server/tools/graph_spec.cr` — 21 specs covering:
  - Tool metadata (name, description, schema declaration)
  - Error handling (missing params, unknown analysis, file not found)
  - Analysis enum validation (all 9 types parse correctly)
  - Summary analysis (files, functions, classes, call edges, imports)
  - Callers analysis (finds callers of target, missing param error)
  - Callees analysis (finds callees of source function)
  - Reachability analysis (reachable + unreachable paths)
  - Dead-code analysis (finds uncalled non-export functions)
  - Cycles analysis (acyclic + cyclic graph detection)
  - Path analysis (finds call path, empty paths for unreachable)
  - Impact analysis (finds functions affected by target change)
  - Facts analysis (generates Prolog facts from code graph)

#### General spec quality

- `[x]` Learn tool: 5→7 specs (added metadata, required-param validation)
- `[x]` Formalize tool: 2→5 specs (added metadata, empty problem, schema declaration)

---

### T1: Upstream Test Parity — In Progress

**Goal:** match upstream test coverage. Full audit completed — 254 upstream tests across 22 test files.

| Status | Count | % |
|--------|:-----:|:--:|
| Covered | 53 | 21% |
| Partial | 18 | 7% |
| Missing | 183 | 72% |
| **Total** | **254** | 100% |

#### Quick Wins (existing spec files, small additions)

- [ ] `lint_spec.cr`: +3 tests (unbalanced parentheses, get-model/set-logic removal, valid spec passes clean)
- [ ] `verify_spec.cr`: edge cases (trace on ground query, trace with multiple rules, empty input error)
- [ ] `skills_spec.cr`: +2 tests (filter by domain, relevance sorting)

#### Medium Effort (existing spec files, significant additions)

- [ ] `formalize_spec.cr`: +3 tests (different problem types: rule-inference, data-flow, dependency)
- [ ] `solve_spec.cr`: +3 tests (Prolog end-to-end, correction loop, template reuse tracking)
- [ ] `craft_spec.cr`: +5 tests (test=true parameter, Prolog crafting, unit validation per field)
- [ ] `learn_spec.cr`: +3 tests (Prolog extraction, invalid JSON handling, promotion)
- [ ] `graph_spec.cr`: MCP integration tests (+5 tests with real files)

#### New Spec Files Needed (new Crystal test infrastructure)

- [ ] `spec/solvers/z3_solver_spec.cr` — 11 tests (direct solver unit tests)
- [ ] `spec/solvers/prolog_solver_spec.cr` — 12 tests
- [ ] `spec/solvers/session_spec.cr` — 4 tests (isolated solver sessions)
- [ ] `spec/solvers/correction_loop_spec.cr` — 10 tests
- [ ] `spec/formalize/feedback_spec.cr` — 7 tests (result classification)
- [ ] `spec/graph/facts_spec.cr` — 9 tests (escapeAtom, Prolog generation)
- [ ] `spec/graph/mermaid_spec.cr` — 16 tests (Mermaid → Prolog parsing)
- [ ] `spec/graph/parser_spec.cr` — 5 tests (language mapping, extensions)
- [ ] `spec/graph/extractor_spec.cr` — 28 tests (TS/Python/Go extraction)
- [ ] `spec/graph/clojure_spec.cr` — 11 tests (Clojure WASM parity)
- [ ] `spec/graph/adapter_registry_spec.cr` — 14 tests
- [ ] `spec/config_spec.cr` — 4 tests (config loading, defaults)
- [ ] `spec/integration/dogfood_spec.cr` — 6 tests (realistic end-to-end)

---

### T2: Parameter Parity — Pending

**Goal:** ensure Crystal tool parameters match upstream schema exactly.

- [ ] `chiasmus_verify`: upstream uses `input` as primary param; Crystal uses `spec` with `input` fallback. Consider standardizing.
- [ ] `chiasmus_skills`: Crystal adds `limit` parameter (not in upstream). Keep if useful, document divergence.
- [ ] `chiasmus_graph`: Crystal adds many more languages. Document as enhancement.
- [ ] Review all tool response shapes for upstream parity

---

### T3: Transport Integration — Partial

**Goal:** all tools covered by MCP transport-level specs.

| Tool | Direct Specs | Transport Specs |
|------|:-----------:|:--------------:|
| verify | ✓ | ✓ |
| graph | ✗ | ✗ |
| skills | ✓ | — (requires `current_server` mock) |
| formalize | ✓ | — |
| solve | ✓ | — |
| craft | ✓ | — |
| learn | ✓ | — |
| lint | ✓ | — |
| crig | ✓ | — |

- [ ] Add graph tool to transport harness specs
- [ ] Wire remaining tools to transport harness (blocked by `MCPServer.current_server` dependency)

---

## Implementation History

| Phase | Status |
|-------|--------|
| Initial port | All 8 upstream tools ported + 1 Crystal-only |
| Tool schemas | Ported (`tool_schemas.cr`, 317 lines) |
| Supporting infrastructure | All formalize, skills, solvers, graph modules ported |
| T0: Graph + under-speced tools | Graph: 26 specs; Learn: 8 specs; Formalize: 6 specs; Lint: 10 specs; Skills: 7 specs; Solve: 4 specs |

## Current State

- 8 ported tools + 1 Crystal-only (9 total)
- 78 tool-level specs across 9 spec files
- All 9 tools have direct spec coverage
- Transport harness covers `verify` and `graph` (2 of 9 tools)
- 571 total specs project-wide, 0 failures

## Next Steps

1. ~~Write specs for `chiasmus_graph` (T0)~~ Done
2. Short-term: Review upstream `tools.test.ts` and `mcp.test.ts` for missed cases (T1)
3. Medium-term: Parameter naming audit (T2)
4. Long-term: Full transport integration for all tools (T3)
