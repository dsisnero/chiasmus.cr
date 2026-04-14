# Pull Request Workflow

## Overview

This document outlines the workflow for contributing changes to the chiasmus Crystal port via pull requests.

## Branch Strategy

- **main**: Stable, deployable code
- **feature/***: New features or enhancements
- **fix/***: Bug fixes
- **port/***: Porting work from upstream
- **docs/***: Documentation updates

## PR Creation Process

### 1. Pre-PR Checklist

Before creating a PR, ensure:

- [ ] Tests pass: `make test`
- [ ] Code is formatted: `make format`
- [ ] Linting passes: `make lint`
- [ ] Parity inventory is updated (if porting work)
- [ ] Documentation is updated (if API changes)

### 2. Create Feature Branch

```bash
git checkout -b feature/your-feature-name
# or
git checkout -b port/upstream-component-name
```

### 3. Make Changes

Follow the coding guidelines in `docs/CODING-GUIDELINES.md`:
- Write tests first for new features
- Update parity inventory for porting work
- Document public API changes

### 4. Commit Changes

Use descriptive commit messages:

```
feat: Add Z3 solver integration
fix: Handle empty input in parse_mermaid
port: Translate verification engine from TypeScript
docs: Update API documentation for CallGraph
```

### 5. Update Parity Inventory

For porting work, update `plans/inventory/typescript_port_inventory.tsv`:

```bash
# Mark items as in_progress, partial, or ported
# Update crystal_refs with Crystal implementation locations
# Add notes for any deviations from upstream
```

### 6. Run Quality Gates

```bash
make format
make lint
make test
```

### 7. Create Pull Request

Create a PR with:
- **Title**: Descriptive summary (e.g., "Port verification engine from TypeScript")
- **Description**:
  - Summary of changes
  - Upstream reference (commit/tag)
  - Parity status updates
  - Testing performed
- **Labels**: Add appropriate labels (porting, bug, enhancement, etc.)

## PR Review Process

### Reviewer Responsibilities

1. **Code Quality**:
   - Follows Crystal conventions
   - Proper error handling
   - Adequate test coverage

2. **Porting Faithfulness**:
   - Behavior matches upstream
   - Tests are properly ported
   - Edge cases are handled

3. **Documentation**:
   - Public APIs are documented
   - Examples are provided for complex features
   - README/guides are updated if needed

4. **Parity Tracking**:
   - Inventory is properly updated
   - crystal_refs are accurate
   - Notes explain any deviations

### Review Checklist

- [ ] Code follows project conventions
- [ ] Tests pass and cover changes
- [ ] No regression in existing functionality
- [ ] Parity inventory is updated (if applicable)
- [ ] Documentation is updated
- [ ] Commit history is clean and logical

## PR Approval Criteria

A PR can be merged when:

1. **All checks pass**: CI, tests, linting, formatting
2. **Required reviews**: At least one maintainer approval
3. **No blocking comments**: All feedback addressed
4. **Parity verified**: For porting work, inventory shows correct status

## Special Cases

### Porting PRs

For PRs that port functionality from upstream:

1. **Reference upstream commit**: Include hash/tag in PR description
2. **Update inventory**: Mark items as `ported` with `crystal_refs`
3. **Verify behavior**: Include evidence of parity (test outputs, etc.)
4. **Document deviations**: Any intentional differences from upstream

### Breaking Changes

For API-breaking changes:

1. **Major version bump**: Update `shard.yml` version
2. **Migration guide**: Document how to update code
3. **Deprecation warnings**: Use `@[Deprecated]` annotation
4. **Parallel support**: Support old API during transition if possible

## Post-Merge

After PR is merged:

1. **Delete feature branch** (if created from fork)
2. **Update local main**: `git checkout main && git pull`
3. **Verify deployment** (if applicable)
4. **Close related issues** (if any)

## Continuous Integration

GitHub Actions automatically runs on PRs:
- `make test` - Runs test suite
- `make lint` - Checks code quality
- `make format` - Verifies code formatting
- Parity checks (for porting PRs)

## Getting Help

If you need help with the PR process:
- Check `docs/DEVELOPMENT.md` for development setup
- Review existing PRs for examples
- Ask in PR comments for clarification
- Contact maintainers for guidance