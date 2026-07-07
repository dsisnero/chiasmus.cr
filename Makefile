.PHONY: help install update format lint test clean build build_release build-clis release dist setup-grammars warm-cache

# Default: show help.
help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "Build targets:"
	@echo "  build              standard release binary (bin/chiasmus)"
	@echo "  build_release      release + -Dpreview_mt -Dexecution_context (parallel extraction)"
	@echo "  warm-cache         build release + warm extraction cache for src/"
	@echo ""
	@echo "QA targets:"
	@echo "  test               run specs"
	@echo "  lint               format check + ameba"
	@echo "  format             auto-format src/ and spec/"
	@echo ""
	@echo "Dependencies:"
	@echo "  install            shards install"
	@echo "  update             shards update"
	@echo "  setup-grammars     install tree-sitter grammars"
	@echo ""
	@echo "Other:"
	@echo "  clean              remove bin/, .build/, .crystal-cache/, dist/"
	@echo "  dist               create distribution tarball"

install:
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

build: $(BUILD_DIR)/chiasmus
$(BUILD_DIR)/chiasmus: $(SRC) $(SHARD_FILES)
	@mkdir -p bin $(BUILD_DIR)
	crystal build --release -o bin/chiasmus src/chiasmus_cli.cr
	@touch $@

build_release: $(BUILD_DIR)/chiasmus_release
$(BUILD_DIR)/chiasmus_release: $(SRC) $(SHARD_FILES)
	@mkdir -p bin $(BUILD_DIR)
	crystal build --release -Dpreview_mt -Dexecution_context -o bin/chiasmus src/chiasmus_cli.cr
	@touch $@

build-clis:
	mkdir -p bin
	crystal build --release -o bin/chiasmus-discover src/chiasmus_discover.cr
	crystal build --release -o bin/chiasmus-grammar src/chiasmus_grammar.cr
	# Build parity CLIs with execution contexts enabled so CHIASMUS_PARITY_PARALLEL
	# can opt into true-thread worker pools for row matching and regex-side scans.
	crystal build --release -Dpreview_mt -Dexecution_context -o bin/chiasmus-parity src/chiasmus_parity.cr
	crystal build --release -o bin/chiasmus-plan src/chiasmus_plan.cr
	crystal build --release -Dpreview_mt -Dexecution_context -o bin/chiasmus-complete src/chiasmus_complete.cr
	# chiasmus-facts is the graph engine headless; build it like the server
	# (-Dpreview_mt -Dexecution_context) so extraction uses true-thread
	# parallelism (parallel_cpu_enabled?) instead of fiber-only.
	crystal build --release -Dpreview_mt -Dexecution_context -o bin/chiasmus-facts src/chiasmus_facts.cr

release:
	mkdir -p bin
	@if crystal build --release --static -o bin/chiasmus-static src/chiasmus_cli.cr 2>/dev/null; then \
		echo "Built static binary"; \
	else \
		echo "Static linking failed, building dynamic binary"; \
		crystal build --release -o bin/chiasmus-static src/chiasmus_cli.cr; \
	fi

# Create distribution package with grammars
dist: release build-clis
	@echo "Creating distribution package..."
	@echo "Note: Ensure grammars are installed first with 'make setup-grammars' or './scripts/setup_grammars.cr'"
	@rm -rf dist
	@mkdir -p dist/chiasmus
	@mkdir -p dist/chiasmus/grammars

	# Copy binary
	@cp bin/chiasmus-static dist/chiasmus/chiasmus
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

clean:
	rm -rf .crystal-cache
	rm -rf bin
	rm -rf dist
	rm -rf .build
