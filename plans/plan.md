# Grammar CLI Enhancement Plan

**Project:** Enhance `chiasmus-grammar` CLI with version tracking and arbitrary URL support  
**Status:** Planning  
**Created:** 2025-04-19  
**Last Updated:** 2025-04-19  

## Overview

Enhance the existing `chiasmus-grammar` CLI to support:
1. Arbitrary git/npm URLs for grammar installation
2. Version tracking via metadata files
3. Update detection and management
4. Parallel downloads and compilation
5. Backward compatibility with existing grammars

## Current State Analysis

### Existing Components
- **CLI target**: `chiasmus-grammar` in `shard.yml` → `src/chiasmus_grammar.cr` → `src/chiasmus/cli.cr`
- **Grammar management**: `GrammarManager` (`src/chiasmus/graph/grammar_manager.cr`) with async npm/git install
- **Language registry**: `LanguageRegistry` with hardcoded package mappings
- **Scripts**: `scripts/download_grammars.cr` and `setup_grammars.cr` with duplicate logic
- **Missing**: Version tracking, arbitrary URL support, update management

### Key Decisions
1. **Per-directory metadata** (`.chiasmus-metadata.json`) over central registry
2. **Commit hash tracking** for git, version for npm (no branch/tag tracking)
3. **Backward compatible** - auto-create metadata for existing grammars
4. **Parallel downloads** - leverage existing async infrastructure
5. **Offline support** - CLI works with cached grammars when offline

## Implementation Plan

### Phase 1: Metadata System ✅
**Status:** Not Started  
**Files:**
- `src/chiasmus/graph/grammar_metadata.cr` (new)
- `spec/chiasmus/graph/grammar_metadata_spec.cr` (new)

**Tasks:**
- [ ] Define `GrammarMetadata` struct with JSON serialization
- [ ] Create `GrammarMetadataStore` to load/save per-directory metadata
- [ ] Implement auto-creation for existing grammars in `vendor/grammars/`
- [ ] Write comprehensive specs for metadata operations

**Metadata Schema (.chiasmus-metadata.json):**
```json
{
  "url": "https://github.com/tree-sitter/tree-sitter-python",
  "type": "git", // "git", "npm", "local"
  "commit_hash": "abc123...",      // git only
  "version": "1.0.0",              // npm only  
  "package_name": "tree-sitter-python",
  "language": "python",            // inferred from package/URL
  "installed_at": "2025-04-19T12:00:00Z",
  "last_updated": "2025-04-19T12:00:00Z"
}
```

### Phase 2: Enhance GrammarManager ✅
**Status:** Not Started  
**Files:**
- `src/chiasmus/graph/grammar_manager.cr` (modify)
- `src/chiasmus/graph/language_registry.cr` (modify)

**Tasks:**
- [ ] Add metadata parameter to `install_via_git_async`/`install_via_npm_async`
- [ ] Store metadata after successful installation
- [ ] Add `update_check_async(language)` to compare local/remote commits
- [ ] Support arbitrary git URLs (not just `tree-sitter/*`)
- [ ] Add `install_from_local_async(path)` for local grammars
- [ ] Add `register_custom_grammar` to `LanguageRegistry`

### Phase 3: Extend CLI Commands ✅
**Status:** Not Started  
**Files:**
- `src/chiasmus/cli.cr` (modify)
- `src/chiasmus_grammar.cr` (modify if needed)

**Tasks:**
- [ ] Add `add <url|package>` command with `--branch`, `--tag`, `--local` options
- [ ] Add `remove <language>` command with `--force` option
- [ ] Enhance `status` command to show version info
- [ ] Add `update` command with `--all`, `--dry-run` options
- [ ] Enhance `list` command to show version info from metadata
- [ ] Enhance `compile` command to use metadata for source determination
- [ ] Update CLI help text and documentation

### Phase 4: Integrate Scripts Logic ✅
**Status:** Not Started  
**Files:**
- `scripts/download_grammars.cr` (rewrite)
- `scripts/setup_grammars.cr` (rewrite)
- `Makefile` (update if needed)

**Tasks:**
- [ ] Move hardcoded language lists from scripts to `LanguageRegistry` as default grammars
- [ ] Rewrite scripts to use new CLI commands
- [ ] Keep scripts as thin convenience wrappers
- [ ] Update `make dist` to use new CLI for grammar preparation

### Phase 5: Testing (TDD) ✅
**Status:** Not Started  
**Files:**
- `spec/chiasmus/cli_spec.cr` (new)
- `spec/chiasmus/graph/grammar_metadata_spec.cr` (new)
- Update existing specs

**Tasks:**
- [ ] Test each CLI command with mocked git/npm
- [ ] Test metadata serialization and storage
- [ ] Integration tests for actual git/npm installation (optional)
- [ ] Ensure existing tests pass (`make test`)

### Phase 6: Documentation & Polish ✅
**Status:** Not Started  
**Files:**
- `README.md` (update)
- `docs/` (add examples)
- `AGENTS.md` (update if needed)

**Tasks:**
- [ ] Update CLI help text and README with examples
- [ ] Run quality gates: `make format`, `make lint`, `make test`
- [ ] Create example usage in `docs/`
- [ ] Verify backward compatibility

## Quality Gates

Each phase must pass:
- [ ] `make format` - Crystal formatter
- [ ] `make lint` - Ameba linter
- [ ] `make test` - All specs pass

## Open Questions

1. **Multiple grammars per language**: Should we support different forks of the same language? (Decision: No for now, warn on conflict)
2. **Compilation flags**: Include in metadata? (Decision: Not needed for now)
3. **Dependency chain updates**: Handle TypeScript → JavaScript during updates? (Decision: Update dependencies first)

## Dependencies

- `tree-sitter-cli` must be installed for compilation
- Git must be available for git operations
- NPM must be available for npm operations
- C compiler (cc/gcc/clang) for building grammars

## Success Criteria

1. All existing functionality preserved
2. New CLI commands work as specified
3. Metadata correctly tracks versions
4. Update detection works for git/npm sources
5. Backward compatibility with existing `vendor/grammars/`
6. All tests pass
7. Quality gates pass

## Progress Tracking

| Phase | Status | Started | Completed | Notes |
|-------|--------|---------|-----------|-------|
| 1 | Not Started | - | - | |
| 2 | Not Started | - | - | |
| 3 | Not Started | - | - | |
| 4 | Not Started | - | - | |
| 5 | Not Started | - | - | |
| 6 | Not Started | - | - | |

## Notes

- Follow TDD: Write tests first, then implementation
- Leverage existing async infrastructure in `GrammarManager`
- Maintain backward compatibility at all times
- Use existing patterns and conventions from codebase