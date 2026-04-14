# Testing Guide

## Testing Strategy

This project uses a test-driven porting approach:

1. **Port tests first** - Translate upstream TypeScript tests to Crystal specs
2. **Preserve test logic** - Keep assertions and test cases identical
3. **Verify behavior** - Ensure Crystal implementation matches upstream behavior

## Test Structure

- **Unit tests**: `spec/unit/` - Test individual components in isolation
- **Integration tests**: `spec/integration/` - Test component interactions
- **Porting tests**: `spec/porting/` - Tests ported from upstream

## Running Tests

```bash
# Run all tests
make test

# Run specific test file
crystal spec spec/unit/verification/z3_spec.cr

# Run tests with verbose output
crystal spec --verbose

# Run tests with fail-fast
crystal spec --fail-fast
```

## Test Dependencies

- **Crystal spec**: Built-in testing framework
- **WebMock** (if needed): HTTP request mocking
- **Timecop** (if needed): Time manipulation for tests

## Porting TypeScript Tests

When porting TypeScript tests to Crystal:

### 1. Test File Structure

TypeScript (Vitest/Jest):
```typescript
describe("Z3Solver", () => {
  it("solves basic constraints", () => {
    const solver = new Z3Solver();
    const result = solver.solve("(declare-const x Int) (assert (> x 0))");
    expect(result.status).toBe("sat");
  });
});
```

Crystal:
```crystal
describe Z3Solver do
  it "solves basic constraints" do
    solver = Z3Solver.new
    result = solver.solve("(declare-const x Int) (assert (> x 0))")
    result.status.should eq("sat")
  end
end
```

### 2. Assertion Mapping

| TypeScript | Crystal |
|------------|---------|
| `expect(x).toBe(y)` | `x.should eq(y)` |
| `expect(x).toBeTruthy()` | `x.should be_truthy` |
| `expect(x).toBeFalsy()` | `x.should be_falsey` |
| `expect(x).toThrow()` | `expect_raises(Error) { x }` |
| `expect(x).toContain(y)` | `x.should contain(y)` |

### 3. Async Test Handling

TypeScript:
```typescript
it("handles async operations", async () => {
  const result = await asyncOperation();
  expect(result).toBeDefined();
});
```

Crystal:
```crystal
it "handles async operations" do
  channel = Channel(Result).new
  spawn do
    result = async_operation
    channel.send(result)
  end
  
  result = channel.receive
  result.should_not be_nil
end
```

### 4. Test Fixtures

Preserve upstream test fixtures exactly:
- Copy fixture files from `vendor/chiasmus/tests/fixtures/` to `spec/fixtures/`
- Use relative paths in tests
- Verify fixture content matches

## Test Coverage

- Aim for 100% test coverage of ported functionality
- Use `crystal tool coverage` to generate coverage reports
- Track coverage gaps in `plans/inventory/`

## Continuous Integration

Tests run automatically on:
- `make test` - Local development
- GitHub Actions - CI pipeline
- Pre-commit hooks - Quality gate

## Debugging Tests

```bash
# Run with debug output
DEBUG=true crystal spec

# Run specific test line
crystal spec spec/unit/verification/z3_spec.cr:15

# Use binding.pry for debugging
require "pry"
binding.pry
```