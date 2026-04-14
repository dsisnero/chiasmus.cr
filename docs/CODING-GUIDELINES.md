# Coding Guidelines

## Crystal Style Guide

Follow the [Crystal style guide](https://crystal-lang.org/reference/conventions/coding_style.html) with these project-specific additions:

### Naming Conventions

- **Modules**: `PascalCase` (e.g., `Chiasmus`, `Verification`)
- **Classes**: `PascalCase` (e.g., `Z3Solver`, `CallGraphAnalyzer`)
- **Methods**: `snake_case` (e.g., `parse_mermaid`, `verify_spec`)
- **Constants**: `SCREAMING_SNAKE_CASE` (e.g., `DEFAULT_TIMEOUT`, `MAX_ITERATIONS`)
- **Variables**: `snake_case` (e.g., `file_path`, `result_set`)

### Type Annotations

- Always use explicit type annotations for public API methods
- Use union types for optional/multiple return types
- Prefer `Nil` over `nil` in type annotations

```crystal
# Good
def parse_spec(input : String) : SpecResult?
def analyze(graph : CallGraph) : AnalysisResult

# Avoid
def parse_spec(input)
def analyze(graph)
```

### Error Handling

- Use exceptions for unexpected errors
- Use `Result` types for expected error cases
- Document exceptions in method documentation

```crystal
# For unexpected errors
raise ArgumentError.new("Input cannot be empty") if input.empty?

# For expected error cases
def verify(spec : String) : VerificationResult
  # Returns VerificationResult with success/failure
end
```

### Porting from TypeScript

When porting TypeScript code:

1. **Preserve behavior exactly** - Don't "improve" logic unless it fixes a bug
2. **Map types carefully**:
   - `string` → `String`
   - `number` → `Int32`/`Int64`/`Float64` (choose based on usage)
   - `boolean` → `Bool`
   - `any` → Use union types or generic constraints
   - `Promise<T>` → `Future(T)` or `Channel(T)`
3. **Handle async patterns**:
   - `async/await` → `spawn` + `Channel` or `Future`
   - Callbacks → blocks or `Proc` types

### Testing Conventions

- Write specs in `spec/` directory
- Use descriptive test names
- Follow Arrange-Act-Assert pattern
- Port upstream tests exactly

### Documentation

- Document all public APIs with YARD-style comments
- Include examples for complex methods
- Update documentation when changing behavior

```crystal
# Parses a Mermaid flowchart into a call graph
#
# @param mermaid [String] Mermaid diagram text
# @return [CallGraph] Parsed call graph
# @raise [ParseError] If the Mermaid syntax is invalid
#
# @example
#   graph = parse_mermaid("graph TD\n  A --> B")
def parse_mermaid(mermaid : String) : CallGraph
  # ...
end
```