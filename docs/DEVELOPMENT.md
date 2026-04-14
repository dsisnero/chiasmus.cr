# Development Guide

## Setup

1. Install Crystal: https://crystal-lang.org/install/
2. Install shards: `brew install crystal` (includes shards on macOS)
3. Clone repository: `git clone --recursive https://github.com/dsisnero/code_rule.git`
4. Install dependencies: `make install`

## Workflow

### Code Quality

```bash
make format    # Format code
make lint      # Run linters
make test      # Run tests
```

### Porting New Features

1. **Inventory first**: Use `cross-language-crystal-parity` to track API/test parity
2. **Behavior faithfulness**: Preserve upstream semantics exactly
3. **Test-driven**: Port tests before implementation
4. **Continuous verification**: Run quality gates frequently

### Testing Strategy

- Port upstream tests as Crystal specs
- Preserve test logic and assertions exactly
- Add characterization specs for untested behavior
- Maintain fixture parity with upstream

## Debugging

### Common Issues

1. **Type mismatches**: TypeScript `number` → Crystal `Int32`/`Int64`/`Float64`
2. **Async patterns**: TypeScript `Promise` → Crystal `Future`/`Channel`
3. **Error handling**: TypeScript `try/catch` → Crystal `begin/rescue`
4. **Binary data**: TypeScript `Buffer` → Crystal `Bytes` (`Slice(UInt8)`)

### Tools

- `crystal spec --verbose` - Detailed test output
- `crystal tool context` - Show compilation context
- `ameba --only Lint/UnusedArgument` - Focus on specific lint rules

## Contributing

See `CONTRIBUTING.md` for contribution guidelines.