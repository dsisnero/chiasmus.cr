# Crolog Shard Patch: Missing SWI-Prolog Bindings

## Issue
The crolog shard is missing several SWI-Prolog C API bindings required for chiasmus MCP server functionality:
1. Missing CVT_* constants (CVT_ATOM, CVT_STRING, CVT_LIST, CVT_INTEGER, CVT_RATIONAL, CVT_FLOAT, CVT_VARIABLE, CVT_WRITE, CVT_WRITEQ, CVT_EXCEPTION, CVT_ALL, BUF_STACK, BUF_RING)
2. Missing functions: PL_exception, PL_clear_exception, PL_chars_to_term, PL_put_variable, PL_get_chars, PL_get_arg, PL_get_list, PL_get_nil
3. Syntax error in `term_n` macro: `((({{term}} as UInt8*) + {{n}}) as LibProlog::Term)` has unbalanced parentheses

## Reproduction

### Before fix:
```bash
# Clone original crolog
git clone https://github.com/bcardiff/crolog.git
cd crolog

# Check if CVT_ATOM is defined
crystal eval 'require "./src/crolog"; puts LibProlog::CVT_ATOM'
# Error: undefined constant LibProlog::CVT_ATOM

# Run tests
crystal spec
# Error: There was a problem expanding macro 'term_n'
```

### After fix (our fork):
```bash
# Use forked version
git clone https://github.com/dsisnero/crolog.git
cd crolog
git checkout feat/add-missing-swipl-bindings

# Check if CVT_ATOM is defined
crystal eval 'require "./src/crolog"; puts LibProlog::CVT_ATOM'
# Output: 1

# Run tests
crystal spec spec/missing_bindings_spec.cr
# 10 examples, 0 failures
```

## Patch Details

### Files modified:
1. `src/crolog/lib_prolog.cr` - Added missing constants and function declarations
2. `src/crolog/macros/utils.cr` - Fixed `term_n` macro syntax error
3. `spec/missing_bindings_spec.cr` - Added comprehensive tests

### Changes:
1. Added CVT_* constants after PL_INTEGER constant
2. Added PL_exception, PL_clear_exception, PL_chars_to_term functions after PL_close_query
3. Added PL_put_variable function after PL_put_int64
4. Added PL_get_chars, PL_get_arg, PL_get_list, PL_get_nil functions after PL_get_integer
5. Fixed `term_n` macro from `((({{term}} as UInt8*) + {{n}}) as LibProlog::Term)` to `{{term}} + {{n}}`

## Host Project Integration

The chiasmus project (`code_rule`) depends on these bindings:
- `prolog_solver.cr` uses `CVT_ALL`, `CVT_WRITEQ`, and `BUF_RING` constants
- Other functions may be needed for future Prolog integration features

## PR Status
**Fork URL**: https://github.com/dsisnero/crolog/tree/feat/add-missing-swipl-bindings
**PR Creation URL**: https://github.com/dsisnero/crolog/pull/new/feat/add-missing-swipl-bindings
**Upstream**: https://github.com/bcardiff/crolog

**Waiting for user approval before creating PR to upstream.**

## Verification

Host project (`code_rule`) shard.yml configuration:
```yaml
crolog:
  github: dsisnero/crolog
  branch: feat/add-missing-swipl-bindings
```

Host project tests pass:
```bash
cd /Users/dominic/repos/github.com/dsisnero/code_rule
make test
# 57 examples, 0 failures, 0 errors, 0 pending
```