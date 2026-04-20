.PHONY: install update format lint test clean build release dist setup-grammars

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
	crystal spec

build:
	mkdir -p bin
	crystal build --release -o bin/chiasmus src/chiasmus.cr

release:
	mkdir -p bin
	# Try static linking, fall back to dynamic if it fails
	@if crystal build --release --static -o bin/chiasmus-static src/chiasmus.cr 2>/dev/null; then \
		echo "Built static binary"; \
	else \
		echo "Static linking failed, building dynamic binary"; \
		crystal build --release -o bin/chiasmus-static src/chiasmus.cr; \
	fi

# Create distribution package with grammars
dist: release
	@echo "Creating distribution package..."
	@echo "Note: Ensure grammars are installed first with 'make setup-grammars' or './scripts/setup_grammars.cr'"
	@rm -rf dist
	@mkdir -p dist/chiasmus
	@mkdir -p dist/chiasmus/grammars
	
	# Copy binary
	@cp bin/chiasmus-static dist/chiasmus/chiasmus
	
	# Copy grammar libraries from cache
	@echo "Copying grammar libraries from cache..."
	@for lang in ruby python java go rust scala javascript typescript tsx crystal; do \
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
			cp vendor/grammars/tree-sitter-typescript/typescript/$$lib_name dist/chiasmus/grammars/ 2>/dev/null || echo "  Warning: $$lang not found"; \
		elif [ "$$lang" = "tsx" ]; then \
			cp vendor/grammars/tree-sitter-typescript/tsx/libtree-sitter-tsx.$$ext dist/chiasmus/grammars/ 2>/dev/null || echo "  Warning: $$lang not found"; \
		else \
			cp vendor/grammars/tree-sitter-$$lang/$$lib_name dist/chiasmus/grammars/ 2>/dev/null || echo "  Warning: $$lang not found"; \
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
	
	# Create tarball
	@cd dist && tar czf chiasmus-$(shell date +%Y%m%d).tar.gz chiasmus/
	@echo "Distribution package created: dist/chiasmus-$(shell date +%Y%m%d).tar.gz"

# Set up grammars using the new CLI
setup-grammars: build
	@echo "Setting up grammars using chiasmus-grammar CLI..."
	@./scripts/setup_grammars_new.cr

clean:
	rm -rf .crystal-cache
	rm -rf bin
	rm -rf dist