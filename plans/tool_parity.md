# Chiasmus MCP Tool Parity Plan

## Summary

All 8 upstream tools are ported to Crystal. The main gap is `chiasmus_graph` spec coverage.

| Tool | Upstream | Crystal | Specs | Status |
|------|:--------:|:-------:|:-----:|:------:|
| `chiasmus_verify` | ✓ | ✓ | ✓ (12) | Complete |
| `chiasmus_skills` | ✓ | ✓ | ✓ (5) | Complete |
| `chiasmus_formalize` | ✓ | ✓ | ✓ (5) | Complete |
| `chiasmus_solve` | ✓ | ✓ | ✓ (3) | Complete |
| `chiasmus_learn` | ✓ | ✓ | ✓ (7) | Complete |
| `chiasmus_lint` | ✓ | ✓ | ✓ (4) | Complete |
| `chiasmus_graph` | ✓ | ✓ | ✓ (21) | Complete |
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

### T1: Upstream Test Parity — Pending

**Goal:** match upstream test coverage for each tool.

Upstream test files in `vendor/chiasmus/tests/`:
- `tests/tools.test.ts` — tool schema + handler registration tests
- `tests/mcp.test.ts` — end-to-end transport tests (verify, skills, formalize, solve, etc.)
- `tests/graph/` — per-language graph tests (TypeScript, Python, Go, JavaScript, Clojure)

**Porting plan:**

- [ ] Review `vendor/chiasmus/tests/tools.test.ts` for any uncovered edge cases
- [ ] Review `vendor/chiasmus/tests/mcp.test.ts` for transport-level parity gaps
- [ ] Port any remaining upstream test cases not already covered by existing Crystal specs
- [ ] Add multi-language graph walker tests for all 19 supported languages

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
| T0: Graph + under-speced tools | Graph: 21 specs; Learn: 7 specs; Formalize: 5 specs |

## Current State

- 8 ported tools + 1 Crystal-only (9 total)
- 61 tool specs across 9 spec files
- All 9 tools have direct spec coverage
- Transport harness covers `verify` and `graph` (2 of 9 tools)

## Next Steps

1. ~~Immediate: Write specs for `chiasmus_graph` (T0)~~ Done
2. Short-term: Review upstream `tools.test.ts` and `mcp.test.ts` for missed cases (T1)
3. Medium-term: Parameter naming audit (T2)
4. Long-term: Full transport integration for all tools (T3)
