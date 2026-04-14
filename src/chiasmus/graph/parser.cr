require "tree_sitter"
require "./types"
require "./universal_parser"
require "./async_universal_parser_v2"
require "../utils/timeout"

module Chiasmus
  module Graph
    module Parser
      extend self

      # Language configuration for tree-sitter grammars
      # Note: In Crystal, we need to have the tree-sitter language shared libraries
      # installed in the standard locations or configured via tree-sitter config
      LANGUAGE_CONFIG = {
        # JavaScript/TypeScript family
        "typescript" => {package: "tree-sitter-typescript", module_export: "typescript"},
        "tsx"        => {package: "tree-sitter-typescript", module_export: "tsx"},
        "javascript" => {package: "tree-sitter-javascript"},

        # Python
        "python" => {package: "tree-sitter-python"},

        # Go
        "go" => {package: "tree-sitter-go"},

        # Clojure (WASM-based)
        "clojure" => {package: "@yogthos/tree-sitter-clojure", wasm: true, wasm_file: "tree-sitter-clojure.wasm"},

        # Crystal
        "crystal" => {package: "tree-sitter-crystal"},

        # C/C++ family
        "c"      => {package: "tree-sitter-c"},
        "cpp"    => {package: "tree-sitter-cpp"},
        "csharp" => {package: "tree-sitter-c-sharp"},

        # Java family
        "java"   => {package: "tree-sitter-java"},
        "kotlin" => {package: "tree-sitter-kotlin"},
        "scala"  => {package: "tree-sitter-scala"},

        # Ruby
        "ruby" => {package: "tree-sitter-ruby"},

        # Rust
        "rust" => {package: "tree-sitter-rust"},

        # PHP
        "php" => {package: "tree-sitter-php"},

        # Swift
        "swift" => {package: "tree-sitter-swift"},

        # Haskell
        "haskell" => {package: "tree-sitter-haskell"},

        # Web technologies
        "html" => {package: "tree-sitter-html"},
        "css"  => {package: "tree-sitter-css"},

        # Shell scripting
        "bash" => {package: "tree-sitter-bash"},

        # Configuration/data formats
        "json" => {package: "tree-sitter-json"},
        "yaml" => {package: "tree-sitter-yaml"},
        "toml" => {package: "tree-sitter-toml"},

        # Markup/documentation
        "markdown" => {package: "tree-sitter-markdown"},

        # SQL
        "sql" => {package: "tree-sitter-sql"},

        # Other languages
        "lua"    => {package: "tree-sitter-lua"},
        "dart"   => {package: "tree-sitter-dart"},
        "elixir" => {package: "tree-sitter-elixir"},
        "erlang" => {package: "tree-sitter-erlang"},
        "ocaml"  => {package: "tree-sitter-ocaml"},
        "perl"   => {package: "tree-sitter-perl"},
        "r"      => {package: "tree-sitter-r"},
        "zig"    => {package: "tree-sitter-zig"},
      }

      # Map file extensions to language names
      EXT_MAP = {
        # JavaScript/TypeScript
        ".ts"  => "typescript",
        ".tsx" => "tsx",
        ".mts" => "typescript",
        ".cts" => "typescript",
        ".js"  => "javascript",
        ".jsx" => "javascript",
        ".mjs" => "javascript",
        ".cjs" => "javascript",

        # Python
        ".py"  => "python",
        ".pyw" => "python",
        ".pyi" => "python",

        # Go
        ".go" => "go",

        # Clojure
        ".clj"  => "clojure",
        ".cljs" => "clojure",
        ".cljc" => "clojure",
        ".edn"  => "clojure",

        # Crystal
        ".cr" => "crystal",

        # C/C++
        ".c"   => "c",
        ".h"   => "c",
        ".cpp" => "cpp",
        ".cc"  => "cpp",
        ".cxx" => "cpp",
        ".hpp" => "cpp",
        ".hh"  => "cpp",
        ".hxx" => "cpp",

        # C#
        ".cs" => "csharp",

        # Java
        ".java" => "java",

        # Kotlin
        ".kt"  => "kotlin",
        ".kts" => "kotlin",

        # Scala
        ".scala" => "scala",
        ".sc"    => "scala",

        # Ruby
        ".rb"      => "ruby",
        ".rake"    => "ruby",
        ".gemspec" => "ruby",

        # Rust
        ".rs" => "rust",

        # PHP
        ".php"   => "php",
        ".phtml" => "php",
        ".php3"  => "php",
        ".php4"  => "php",
        ".php5"  => "php",
        ".php7"  => "php",
        ".phps"  => "php",

        # Swift
        ".swift" => "swift",

        # Haskell
        ".hs"  => "haskell",
        ".lhs" => "haskell",

        # HTML/CSS
        ".html"  => "html",
        ".htm"   => "html",
        ".xhtml" => "html",
        ".css"   => "css",
        ".scss"  => "css",
        ".sass"  => "css",
        ".less"  => "css",

        # Bash/Shell
        ".sh"   => "bash",
        ".bash" => "bash",
        ".zsh"  => "bash",

        # JSON/YAML/TOML
        ".json" => "json",
        ".yaml" => "yaml",
        ".yml"  => "yaml",
        ".toml" => "toml",

        # Markdown
        ".md"       => "markdown",
        ".markdown" => "markdown",

        # SQL
        ".sql" => "sql",

        # Lua
        ".lua" => "lua",

        # Dart
        ".dart" => "dart",

        # Elixir
        ".ex"  => "elixir",
        ".exs" => "elixir",

        # Erlang
        ".erl" => "erlang",
        ".hrl" => "erlang",

        # OCaml
        ".ml"  => "ocaml",
        ".mli" => "ocaml",

        # Perl
        ".pl" => "perl",
        ".pm" => "perl",

        # R
        ".r" => "r",
        ".R" => "r",

        # Zig
        ".zig" => "zig",
      }

      # Get the tree-sitter language name for a file path
      def get_language_for_file(file_path : String) : String?
        ext = File.extname(file_path).downcase
        # Check built-in first, then registered adapters
        EXT_MAP[ext]? || get_adapter_for_ext(ext).try(&.language)
      end

      # Get all supported file extensions
      def get_supported_extensions : Array(String)
        EXT_MAP.keys + get_adapter_extensions
      end

      # Parse source code synchronously
      # Returns a TreeSitter::Tree or nil if language is not supported
      def parse_source(content : String, file_path : String, timeout_ms : Int32 = 30_000) : TreeSitter::Tree?
        result_channel = parse_source_async(content, file_path, timeout_ms)
        result = Utils::Timeout.with_timeout_async(timeout_ms, result_channel)
        return nil unless result && result.success?

        result.value
      end

      # Parse source code asynchronously using fibers/channels
      # Returns a Channel that will receive a Result(TreeSitter::Tree?)
      def parse_source_async(content : String, file_path : String, timeout_ms : Int32 = 30_000) : Channel(Utils::Result(TreeSitter::Tree?))
        # Use the async universal parser
        AsyncUniversalParserV2.parse_async(content, file_path, timeout_ms)
      end

      private def load_language_sync(language : String) : TreeSitter::Language?
        # Check if language is in our config
        config = LANGUAGE_CONFIG[language]?
        return nil unless config

        # For WASM languages (like Clojure), we can't load them synchronously
        # in the same way as native tree-sitter grammars
        if config[:wasm]?
          # WASM grammars require special handling
          # For now, return nil since we don't have web-tree-sitter equivalent in Crystal
          return nil
        end

        # Try to load the language from tree-sitter repository
        TreeSitter::Repository.load_language?(language)
      rescue ex
        # Language not available
        nil
      end

      # Helper methods that delegate to adapter registry
      # These will be implemented when adapter registry is ported
      private def get_adapter_for_ext(ext : String) : LanguageAdapter?
        nil
      end

      private def get_adapter_extensions : Array(String)
        [] of String
      end
    end
  end
end
