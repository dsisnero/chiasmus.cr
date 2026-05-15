require "tree_sitter"
require "./discovery/grammar_loader"
require "./discovery/predicate_evaluator"
require "./discovery/extractor"
require "./discovery/registry"
require "./discovery/pipeline"
require "./discovery/extractors/*"

# Tree-sitter Discovery module for TypeScript source code analysis.
#
# Uses tree-sitter queries to extract declarations (classes, interfaces,
# types, functions, methods, constants, tests) with stable IDs matching
# the parity inventory format: `{relative_path}::{kind}::{name}`.
#
# Supports a regex fallback mode when tree-sitter grammars are unavailable,
# and clearly reports which parser mode was used.
module Chiasmus
  module Discovery
    VERSION = "0.1.0"

    # Represents a discovered symbol.
    record Item,
      id : String,    # e.g. "src/app.ts::class::MyService"
      kind : String,  # class, interface, type, function, method, const, test
      scope : String, # source or test
      name : String,  # Simple name (may be qualified for methods)
      file : String   # Relative file path

    # Result of a discovery operation.
    record Result,
      items : Array(Item),
      parser_mode : String # "tree-sitter" or "regex"

    extend self

    # Lazy-initialized Pipeline backed by ExtractorRegistry.
    # All `discover_file`/`discover_files` calls use this shared pipeline
    # to delegate to language-specific extractors.
    @@pipeline : Pipeline?

    private def pipeline : Pipeline
      @@pipeline ||= begin
        extractors = [
          BashExtractor.new, CExtractor.new, CppExtractor.new,
          CSharpExtractor.new, CrystalExtractor.new, DartExtractor.new,
          GoExtractor.new, JavaExtractor.new, JavaScriptExtractor.new,
          KotlinExtractor.new, PerlExtractor.new, PhpExtractor.new,
          ProtobufExtractor.new, PythonExtractor.new, RubyExtractor.new,
          RustExtractor.new, ScalaExtractor.new, TypeScriptExtractor.new,
          TSXExtractor.new,
        ] of LanguageExtractor
        Pipeline.new(extractors)
      end
    end

    # Delegated to GrammarLoader
    def register_grammar_directory(path : String) : Nil
      GrammarLoader.register_grammar_directory(path)
    end

    def tree_sitter_available?(language : String) : Bool
      GrammarLoader.tree_sitter_available?(language)
    end

    def find_grammar_library(language : String) : String?
      GrammarLoader.find_grammar_library(language)
    end

    def load_language(language : String) : TreeSitter::Language?
      GrammarLoader.load_language(language)
    end

    # Discover declarations in a single file.
    #
    # - `language`: target language (e.g. "typescript")
    # - `source`: source code content
    # - `file_path`: relative file path for ID generation
    # - `force_parser`: force a specific parser ("tree-sitter" or "regex")
    def discover_file(
      language : String,
      source : String,
      file_path : String,
      force_parser : String? = nil,
    ) : Result
      parser_mode = effective_parser_mode(language, force_parser)

      items = if parser_mode == "tree-sitter"
                pipeline.discover_files([{file_path, source}]).items
              else
                discover_with_regex(language, source, file_path)
              end

      Result.new(items: deduplicate(items), parser_mode: parser_mode)
    end

    # Discover declarations across multiple files.
    def discover_files(
      language : String,
      files : Array(Tuple(String, String)), # [(path, content), ...]
      force_parser : String? = nil,
    ) : Result
      parser_mode = effective_parser_mode(language, force_parser)

      all_items = if parser_mode == "tree-sitter"
                    pipeline.discover_files(files).items
                  else
                    files.flat_map { |path, content| discover_with_regex(language, content, path) }
                  end

      Result.new(items: deduplicate(all_items), parser_mode: parser_mode)
    end

    # -- Private implementation --

    private def effective_parser_mode(language : String, force_parser : String?) : String
      if force_parser
        case force_parser
        when "tree-sitter"
          return tree_sitter_available?(language) ? "tree-sitter" : "regex"
        when "regex"
          return "regex"
        else
          raise ArgumentError.new("Invalid parser mode: #{force_parser}")
        end
      end

      # Auto-detect
      tree_sitter_available?(language) ? "tree-sitter" : "regex"
    end

    private def deduplicate(items : Array(Item)) : Array(Item)
      seen = Set(String).new
      items.select { |item| seen.add?(item.id) }
    end

    # -- Tree-sitter discovery --

    private def discover_with_regex(language : String, source : String, file_path : String) : Array(Item)
      case language
      when "typescript", "javascript", "tsx"
        extract_typescript_regex(source, file_path)
      else
        [] of Item
      end
    end

    private def extract_typescript_regex(content : String, file : String) : Array(Item)
      items = [] of Item

      content.each_line do |line|
        stripped = line.strip

        # Strip export keyword
        stripped = stripped.gsub(/^export\s+/, "")

        # Class declarations
        if stripped =~ /^(abstract\s+)?class\s+([A-Z][A-Za-z0-9_$]*)/
          m = $2
          items << Item.new(id: "#{file}::class::#{m}", kind: "class", scope: "source", name: m, file: file)
        end

        # Interface declarations
        if stripped =~ /^interface\s+([A-Z][A-Za-z0-9_$]*)/
          m = $1
          items << Item.new(id: "#{file}::interface::#{m}", kind: "interface", scope: "source", name: m, file: file)
        end

        # Type alias declarations
        if stripped =~ /^type\s+([A-Z][A-Za-z0-9_$]*)\s*=/
          m = $1
          items << Item.new(id: "#{file}::type::#{m}", kind: "type", scope: "source", name: m, file: file)
        end

        # Function declarations
        if stripped =~ /^(async\s+)?function\s+([a-z_][A-Za-z0-9_$]*)/
          m = $2
          items << Item.new(id: "#{file}::function::#{m}", kind: "function", scope: "source", name: m, file: file)
        end

        # Arrow functions (const/let/var name = (...) => ...)
        if stripped =~ /^(const|let|var)\s+([a-z_][A-Za-z0-9_$]*)\s*=\s*(async\s+)?\(/
          m = $2
          items << Item.new(id: "#{file}::function::#{m}", kind: "function", scope: "source", name: m, file: file)
        end

        # Uppercase constants
        if stripped =~ /^(const|let|var)\s+([A-Z][A-Z0-9_$]*)\s*=/
          m = $2
          items << Item.new(id: "#{file}::const::#{m}", kind: "const", scope: "source", name: m, file: file)
        end

        # Test declarations
        if stripped =~ /^(describe|it|test)\s*\(\s*["'](.+?)["']/
          m = $2
          items << Item.new(id: "#{file}::test::#{m}", kind: "test", scope: "test", name: m, file: file)
        end
      end

      items
    end
  end
end
