.PHONY: help install-deps ensure-shards install install-built install-with-build update format lint test clean build build_release build-clis release dist setup-grammars warm-cache

# Default: show help.
help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "Build targets:"
	@echo "  build              release binary (bin/chiasmus)"
	@echo "  build_release      release binary (parallel contexts enabled at runtime)"
	@echo "  warm-cache         build release + warm extraction cache for src/"
	@echo ""
	@echo "QA targets:"
	@echo "  test               run specs"
	@echo "  lint               format check + ameba"
	@echo "  format             auto-format src/ and spec/"
	@echo ""
	@echo "Dependencies:"
	@echo "  install-deps       shards install"
	@echo "  update             shards update"
	@echo "  setup-grammars     install tree-sitter grammars"
	@echo ""
	@echo "Install:"
	@echo "  install            install bin/ artifacts; rebuild only when stale"
	@echo "  install-with-build build release artifacts, then install them"
	@echo ""
	@echo "Other:"
	@echo "  clean              remove bin/, .build/, .crystal-cache/, dist/"
	@echo "  dist               create distribution tarball"

install-deps:
	shards install

update:
	shards update

format:
	crystal tool format src spec

lint:
	crystal tool format --check src spec
	ameba src spec

test:
	crystal spec spec/

SRC := $(shell find src -name "*.cr" -not -name "._*")
SHARD_FILES := shard.yml shard.lock $(shell find lib -name "shard.yml" 2>/dev/null)
BUILD_DIR := .build
SHARDS_STAMP := $(BUILD_DIR)/shards-installed
BUILD_INPUTS := $(SRC) $(SHARD_FILES) Makefile
CLI_STAMPS := $(BUILD_DIR)/chiasmus-discover $(BUILD_DIR)/chiasmus-grammar $(BUILD_DIR)/chiasmus-parity $(BUILD_DIR)/chiasmus-plan $(BUILD_DIR)/chiasmus-complete $(BUILD_DIR)/chiasmus-facts
INSTALL_FLAGS := --release
INSTALL_ARTIFACTS := bin/chiasmus bin/chiasmus-agent bin/chiasmus-grammar bin/chiasmus-discover bin/chiasmus-facts

# Keep pre-built binaries reusable, while ensuring a missing or changed shard
# set is installed before any Crystal compile starts. This is order-only so it
# never makes a fresh binary stale by itself.
ensure-shards:
	@mkdir -p $(BUILD_DIR)
	@if [ ! -d lib/dir-walk ] || [ ! -f $(SHARDS_STAMP) ] || [ shard.yml -nt $(SHARDS_STAMP) ] || [ shard.lock -nt $(SHARDS_STAMP) ]; then \
		shards install --production && touch $(SHARDS_STAMP); \
	fi

$(BUILD_DIR)/chiasmus $(BUILD_DIR)/chiasmus-discover $(BUILD_DIR)/chiasmus-grammar $(BUILD_DIR)/chiasmus-parity $(BUILD_DIR)/chiasmus-plan $(BUILD_DIR)/chiasmus-complete $(BUILD_DIR)/chiasmus-facts $(BUILD_DIR)/chiasmus_release $(BUILD_DIR)/chiasmus_warmed $(INSTALL_ARTIFACTS): | ensure-shards

build: $(BUILD_DIR)/chiasmus
$(BUILD_DIR)/chiasmus: $(BUILD_INPUTS)
	@mkdir -p bin $(BUILD_DIR)
	crystal build --release -o bin/chiasmus src/chiasmus_cli.cr
	@touch $@

build_release: release

build-clis: $(CLI_STAMPS)

$(BUILD_DIR)/chiasmus-discover: $(BUILD_INPUTS)
	@mkdir -p bin $(BUILD_DIR)
	crystal build --release -o bin/chiasmus-discover src/chiasmus_discover.cr
	@touch $@

$(BUILD_DIR)/chiasmus-grammar: $(BUILD_INPUTS)
	@mkdir -p bin $(BUILD_DIR)
	crystal build --release -o bin/chiasmus-grammar src/chiasmus_grammar.cr
	@touch $@


$(BUILD_DIR)/chiasmus-parity: $(BUILD_INPUTS)
	@mkdir -p bin $(BUILD_DIR)
	# Crystal 1.21 execution contexts are runtime APIs; no feature flags are needed.
	crystal build --release -o bin/chiasmus-parity src/chiasmus_parity.cr
	@touch $@

$(BUILD_DIR)/chiasmus-plan: $(BUILD_INPUTS)
	@mkdir -p bin $(BUILD_DIR)
	crystal build --release -o bin/chiasmus-plan src/chiasmus_plan.cr
	@touch $@

$(BUILD_DIR)/chiasmus-complete: $(BUILD_INPUTS)
	@mkdir -p bin $(BUILD_DIR)
	crystal build --release -o bin/chiasmus-complete src/chiasmus_complete.cr
	@touch $@

$(BUILD_DIR)/chiasmus-facts: $(BUILD_INPUTS)
	@mkdir -p bin $(BUILD_DIR)
	# chiasmus-facts uses the same runtime parallel contexts as the server.
	crystal build --release -o bin/chiasmus-facts src/chiasmus_facts.cr
	@touch $@

release: $(BUILD_DIR)/chiasmus_release
$(BUILD_DIR)/chiasmus_release: $(BUILD_INPUTS)
	@mkdir -p bin $(BUILD_DIR)
	@if crystal build --release --static -o bin/chiasmus src/chiasmus_cli.cr 2>/dev/null; then \
		echo "Built static binary"; \
	else \
		echo "Static linking failed, building dynamic binary"; \
		crystal build --release -o bin/chiasmus src/chiasmus_cli.cr; \
	fi
	@touch $@

# Create distribution package with grammars
dist: release build-clis
	@echo "Creating distribution package..."
	@echo "Note: Ensure grammars are installed first with 'make setup-grammars' or './scripts/setup_grammars.cr'"
	@rm -rf dist
	@mkdir -p dist/chiasmus
	@mkdir -p dist/chiasmus/grammars

	# Copy binary
	@cp bin/chiasmus dist/chiasmus/chiasmus
	@cp bin/chiasmus-discover dist/chiasmus/chiasmus-discover
	@cp bin/chiasmus-grammar dist/chiasmus/chiasmus-grammar
	@cp bin/chiasmus-parity dist/chiasmus/chiasmus-parity
	@cp bin/chiasmus-plan dist/chiasmus/chiasmus-plan
	@cp bin/chiasmus-complete dist/chiasmus/chiasmus-complete
	@cp bin/chiasmus-facts dist/chiasmus/chiasmus-facts

	# Copy grammar libraries from cache
	@echo "Copying grammar libraries from cache..."
	@for lang in ruby python java go rust scala javascript typescript tsx crystal bash c cpp c-sharp dart kotlin perl php proto; do \
		ext=dylib; \
		lib_name=libtree-sitter-$$lang.$$ext; \
		\
		# Try cache directory first (new system) \
		cache_dir=$${XDG_CACHE_HOME:-$$HOME/.cache}/chiasmus/grammars; \
		cache_path=$$cache_dir/$$lang/$$lib_name; \
		\
		if [ -f "$$cache_path" ]; then \
			echo "  Copying $$lang from cache..."; \
			cp "$$cache_path" dist/chiasmus/grammars/; \
		# Fall back to vendor directory (old system) \
		elif [ "$$lang" = "typescript" ]; then \
			cp grammars/tree-sitter-typescript/typescript/$$lib_name dist/chiasmus/grammars/ 2>/dev/null || echo "  Warning: $$lang not found"; \
		elif [ "$$lang" = "tsx" ]; then \
			cp grammars/tree-sitter-typescript/tsx/libtree-sitter-tsx.$$ext dist/chiasmus/grammars/ 2>/dev/null || echo "  Warning: $$lang not found"; \
		else \
			cp grammars/tree-sitter-$$lang/$$lib_name dist/chiasmus/grammars/ 2>/dev/null || echo "  Warning: $$lang not found"; \
		fi; \
	done

	# Create README
	@echo "# Chiasmus Distribution" > dist/chiasmus/README.md
	@echo "" >> dist/chiasmus/README.md
	@echo "This is a standalone distribution of Chiasmus with embedded grammar parsers." >> dist/chiasmus/README.md
	@echo "" >> dist/chiasmus/README.md
	@echo "## Included Grammars" >> dist/chiasmus/README.md
	@echo "- Ruby" >> dist/chiasmus/README.md
	@echo "- Python" >> dist/chiasmus/README.md
	@echo "- Java" >> dist/chiasmus/README.md
	@echo "- Go" >> dist/chiasmus/README.md
	@echo "- Rust" >> dist/chiasmus/README.md
	@echo "- Scala" >> dist/chiasmus/README.md
	@echo "- JavaScript" >> dist/chiasmus/README.md
	@echo "- TypeScript" >> dist/chiasmus/README.md
	@echo "- TSX" >> dist/chiasmus/README.md
	@echo "- Crystal" >> dist/chiasmus/README.md
	@echo "" >> dist/chiasmus/README.md
	@echo "## Usage" >> dist/chiasmus/README.md
	@echo "./chiasmus --help" >> dist/chiasmus/README.md
	@echo "./chiasmus-discover --help" >> dist/chiasmus/README.md
	@echo "./chiasmus-parity --help" >> dist/chiasmus/README.md
	@echo "./chiasmus-plan --help" >> dist/chiasmus/README.md
	@echo "./chiasmus-complete --help" >> dist/chiasmus/README.md

	# Create tarball
	@cd dist && tar czf chiasmus-$(shell date +%Y%m%d).tar.gz chiasmus/
	@echo "Distribution package created: dist/chiasmus-$(shell date +%Y%m%d).tar.gz"

# Set up grammars using the new CLI
setup-grammars: build
	@echo "Setting up grammars using chiasmus-grammar CLI..."
	@./scripts/setup_grammars_new.cr

# Warm the extraction cache so subsequent reviews are instant.
warm-cache: $(BUILD_DIR)/chiasmus_warmed
$(BUILD_DIR)/chiasmus_warmed: $(BUILD_DIR)/chiasmus_release
	@./scripts/warm_cache.cr
	@touch $@

# Install artifacts use the same baseline flags as `shards build --release`.
# Their Makefile prerequisite intentionally invalidates them when these flags
# change, while fresh artifacts made by Shards are reused unchanged.
bin/chiasmus: $(BUILD_INPUTS)
	@mkdir -p bin
	crystal build $(INSTALL_FLAGS) -o $@ src/chiasmus_cli.cr

bin/chiasmus-agent: $(BUILD_INPUTS)
	@mkdir -p bin
	crystal build $(INSTALL_FLAGS) -o $@ src/chiasmus-agent.cr

bin/chiasmus-grammar: $(BUILD_INPUTS)
	@mkdir -p bin
	crystal build $(INSTALL_FLAGS) -o $@ src/chiasmus_grammar.cr

bin/chiasmus-discover: $(BUILD_INPUTS)
	@mkdir -p bin
	crystal build $(INSTALL_FLAGS) -o $@ src/chiasmus_discover.cr

bin/chiasmus-facts: $(BUILD_INPUTS)
	@mkdir -p bin
	crystal build $(INSTALL_FLAGS) -o $@ src/chiasmus_facts.cr

# Install existing chiasmus binaries to ~/.local/bin for system-wide use.
# Rebuild only when a tracked input or the Makefile-defined compiler flags changed.
install: $(INSTALL_ARTIFACTS) install-built

install-built:
	@test -x bin/chiasmus || (echo "Missing bin/chiasmus; build first or run 'make install-with-build'" && exit 1)
	@test -x bin/chiasmus-agent || (echo "Missing bin/chiasmus-agent; build first or run 'make install-with-build'" && exit 1)
	@test -x bin/chiasmus-grammar || (echo "Missing bin/chiasmus-grammar; build first or run 'make install-with-build'" && exit 1)
	@test -x bin/chiasmus-discover || (echo "Missing bin/chiasmus-discover; build first or run 'make install-with-build'" && exit 1)
	@test -x bin/chiasmus-facts || (echo "Missing bin/chiasmus-facts; build first or run 'make install-with-build'" && exit 1)
	@mkdir -p $(HOME)/.local/bin
	@echo "Installing chiasmus binaries to $(HOME)/.local/bin..."
	cp bin/chiasmus $(HOME)/.local/bin/chiasmus
	cp bin/chiasmus-grammar $(HOME)/.local/bin/chiasmus-grammar
	cp bin/chiasmus-discover $(HOME)/.local/bin/chiasmus-discover
	cp bin/chiasmus-facts $(HOME)/.local/bin/chiasmus-facts
	cp bin/chiasmus-agent $(HOME)/.local/bin/chiasmus-agent
	@echo "Done. Ensure $(HOME)/.local/bin is on your PATH."

install-with-build: release build-clis
	$(MAKE) install

clean:
	rm -rf .crystal-cache
	rm -rf bin
	rm -rf dist
	rm -rf .build
