# Chiasmus MCP Tool Parity Plan

## Summary

All 8 upstream tools are ported to Crystal. The main gap is `chiasmus_graph` spec coverage.

| Tool | Upstream | Crystal | Specs | Status |
|------|:--------:|:-------:|:-----:|:------:|
| `chiasmus_verify` | ✓ | ✓ | ✓ (12) | Complete |
| `chiasmus_skills` | ✓ | ✓ | ✓ (5) | Complete |
| `chiasmus_formalize` | ✓ | ✓ | ✓ (2) | Complete |
| `chiasmus_solve` | ✓ | ✓ | ✓ (3) | Complete |
| `chiasmus_learn` | ✓ | ✓ | ✓ (2) | Complete |
| `chiasmus_lint` | ✓ | ✓ | ✓ (4) | Complete |
| `chiasmus_graph` | ✓ | ✓ | ✗ (0) | **Needs specs** |
| `chiasmus_craft` | ✓ | ✓ | ✓ (2) | Complete |
| `chiasmus_crig` | — | ✓ | ✓ (2) | Crystal-only |

---

## Phase Plan

### T0: Improve Existing Under-Speced Tools — Pending

#### `chiasmus_graph` — spec needed

**What upstream tests cover:**
- `tests/mcp.test.ts` tests various graph analysis types across multiple languages
- `tests/tools.test.ts` validates tool schema + handler behavior

**What Crystal needs:**

- [ ] `spec/chiasmus/mcp_server/tools/graph_spec.cr` — new spec file
- [ ] Direct handler specs for each analysis type: summary, callers, callees, reachability, dead-code, cycles, path, impact, facts
- [ ] Schema validation: parameter defaults, analysis enum, language list
- [ ] Error handling: invalid analysis, missing params, unsupported language
- [ ] Integration with newly-added extractors (verify graph works for all 19 languages)
- [ ] Transport-level spec via MCP test harness

#### General spec quality

- [ ] Cap each spec file at 5+ tests per tool (learn + formalize have only 2)
- [ ] Add transport-level integration specs for graph tool (others already have specs)
- [ ] Enum validation for all tool schema enums (analysis types, formats, solvers)

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

## Current State

- 8 ported tools + 1 Crystal-only (9 total)
- 34 tool specs across 8 spec files
- `chiasmus_graph` has NO direct spec coverage (largest gap)
- Transport harness covers `verify` and `graph` (2 of 9 tools)

## Next Steps

1. **Immediate:** Write specs for `chiasmus_graph` (T0)
2. **Short-term:** Review upstream `tools.test.ts` and `mcp.test.ts` for missed cases (T1)
3. **Medium-term:** Parameter naming audit (T2)
4. **Long-term:** Full transport integration for all tools (T3)
