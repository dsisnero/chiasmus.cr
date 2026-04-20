require "mutex"

module Chiasmus
  module Graph
    # Centralized language registry following SOLID principles
    # Single Responsibility: Manage language metadata and configuration
    # Open/Closed: Can be extended without modifying existing code
    # Liskov Substitution: Provides consistent interface
    # Interface Segregation: Separate concerns for different use cases
    # Dependency Inversion: Depends on abstractions (interfaces) not concrete implementations
    #
    # Thread-safe for concurrent access in Crystal/Go-style concurrency environment
    module LanguageRegistry
      extend self

      # Language metadata structure
      record LanguageInfo,
        name : String,
        package : String,
        module_export : String? = nil,
        wasm : Bool = false,
        wasm_file : String? = nil,
        preferred_method : Symbol = :git,
        dependencies : Array(String) = [] of String,
        extensions : Array(String) = [] of String

      # Thread-safe initialization using double-checked locking pattern
      private def ensure_initialized
        return if @@initialized

        @@mutex.synchronize do
          return if @@initialized

          registry = build_registry
          @@registry = registry
          @@extension_map = build_extension_map(registry)
          @@initialized = true
        end
      end

      private def registry : Hash(String, LanguageInfo)
        ensure_initialized
        @@registry || raise "Language registry not initialized"
      end

      private def extension_map : Hash(String, String)
        ensure_initialized
        @@extension_map || raise "Language extension map not initialized"
      end

      # Build comprehensive language registry
      private def build_registry : Hash(String, LanguageInfo)
        registry = {} of String => LanguageInfo

        # JavaScript/TypeScript family
        registry["javascript"] = LanguageInfo.new(
          name: "javascript",
          package: "tree-sitter-javascript",
          preferred_method: :npm,
          extensions: [".js", ".jsx", ".mjs", ".cjs"]
        )

        registry["typescript"] = LanguageInfo.new(
          name: "typescript",
          package: "tree-sitter-typescript",
          module_export: "typescript",
          preferred_method: :npm,
          dependencies: ["javascript"],
          extensions: [".ts", ".mts", ".cts"]
        )

        registry["tsx"] = LanguageInfo.new(
          name: "tsx",
          package: "tree-sitter-typescript",
          module_export: "tsx",
          preferred_method: :npm,
          dependencies: ["javascript"],
          extensions: [".tsx"]
        )

        # Python
        registry["python"] = LanguageInfo.new(
          name: "python",
          package: "tree-sitter-python",
          extensions: [".py", ".pyw", ".pyi"]
        )

        # Go
        registry["go"] = LanguageInfo.new(
          name: "go",
          package: "tree-sitter-go",
          extensions: [".go"]
        )

        # Clojure (WASM-based)
        registry["clojure"] = LanguageInfo.new(
          name: "clojure",
          package: "@yogthos/tree-sitter-clojure",
          wasm: true,
          wasm_file: "tree-sitter-clojure.wasm",
          preferred_method: :npm,
          extensions: [".clj", ".cljs", ".cljc", ".edn"]
        )

        # Crystal
        registry["crystal"] = LanguageInfo.new(
          name: "crystal",
          package: "tree-sitter-crystal",
          extensions: [".cr"]
        )

        # C/C++ family
        registry["c"] = LanguageInfo.new(
          name: "c",
          package: "tree-sitter-c",
          extensions: [".c", ".h"]
        )

        registry["cpp"] = LanguageInfo.new(
          name: "cpp",
          package: "tree-sitter-cpp",
          dependencies: ["c"],
          extensions: [".cpp", ".cc", ".cxx", ".hpp", ".hh", ".hxx"]
        )

        registry["csharp"] = LanguageInfo.new(
          name: "csharp",
          package: "tree-sitter-c-sharp",
          extensions: [".cs"]
        )

        # Java family
        registry["java"] = LanguageInfo.new(
          name: "java",
          package: "tree-sitter-java",
          extensions: [".java"]
        )

        registry["kotlin"] = LanguageInfo.new(
          name: "kotlin",
          package: "tree-sitter-kotlin",
          extensions: [".kt", ".kts"]
        )

        registry["scala"] = LanguageInfo.new(
          name: "scala",
          package: "tree-sitter-scala",
          extensions: [".scala", ".sc"]
        )

        # Ruby
        registry["ruby"] = LanguageInfo.new(
          name: "ruby",
          package: "tree-sitter-ruby",
          extensions: [".rb", ".rake", ".gemspec"]
        )

        # Rust
        registry["rust"] = LanguageInfo.new(
          name: "rust",
          package: "tree-sitter-rust",
          extensions: [".rs"]
        )

        # PHP
        registry["php"] = LanguageInfo.new(
          name: "php",
          package: "tree-sitter-php",
          extensions: [".php", ".phtml", ".php3", ".php4", ".php5", ".php7", ".phps"]
        )

        # Swift
        registry["swift"] = LanguageInfo.new(
          name: "swift",
          package: "tree-sitter-swift",
          extensions: [".swift"]
        )

        # Haskell
        registry["haskell"] = LanguageInfo.new(
          name: "haskell",
          package: "tree-sitter-haskell",
          extensions: [".hs", ".lhs"]
        )

        # Web technologies
        registry["html"] = LanguageInfo.new(
          name: "html",
          package: "tree-sitter-html",
          extensions: [".html", ".htm", ".xhtml"]
        )

        registry["css"] = LanguageInfo.new(
          name: "css",
          package: "tree-sitter-css",
          extensions: [".css", ".scss", ".sass", ".less"]
        )

        # Shell scripting
        registry["bash"] = LanguageInfo.new(
          name: "bash",
          package: "tree-sitter-bash",
          extensions: [".sh", ".bash", ".zsh"]
        )

        # Configuration/data formats
        registry["json"] = LanguageInfo.new(
          name: "json",
          package: "tree-sitter-json",
          extensions: [".json"]
        )

        registry["yaml"] = LanguageInfo.new(
          name: "yaml",
          package: "tree-sitter-yaml",
          extensions: [".yaml", ".yml"]
        )

        registry["toml"] = LanguageInfo.new(
          name: "toml",
          package: "tree-sitter-toml",
          extensions: [".toml"]
        )

        # Markup/documentation
        registry["markdown"] = LanguageInfo.new(
          name: "markdown",
          package: "tree-sitter-markdown",
          extensions: [".md", ".markdown"]
        )

        # SQL
        registry["sql"] = LanguageInfo.new(
          name: "sql",
          package: "tree-sitter-sql",
          extensions: [".sql"]
        )

        # Other languages
        registry["lua"] = LanguageInfo.new(
          name: "lua",
          package: "tree-sitter-lua",
          extensions: [".lua"]
        )

        registry["dart"] = LanguageInfo.new(
          name: "dart",
          package: "tree-sitter-dart",
          extensions: [".dart"]
        )

        registry["elixir"] = LanguageInfo.new(
          name: "elixir",
          package: "tree-sitter-elixir",
          extensions: [".ex", ".exs"]
        )

        registry["erlang"] = LanguageInfo.new(
          name: "erlang",
          package: "tree-sitter-erlang",
          extensions: [".erl", ".hrl"]
        )

        registry["ocaml"] = LanguageInfo.new(
          name: "ocaml",
          package: "tree-sitter-ocaml",
          extensions: [".ml", ".mli"]
        )

        registry["perl"] = LanguageInfo.new(
          name: "perl",
          package: "tree-sitter-perl",
          extensions: [".pl", ".pm"]
        )

        registry["r"] = LanguageInfo.new(
          name: "r",
          package: "tree-sitter-r",
          extensions: [".r", ".R"]
        )

        registry["zig"] = LanguageInfo.new(
          name: "zig",
          package: "tree-sitter-zig",
          extensions: [".zig"]
        )

        registry
      end

      # Get language info by name (thread-safe)
      def get_language_info(language : String) : LanguageInfo?
        registry[language]?
      end

      # Get all supported languages (thread-safe)
      def supported_languages : Array(String)
        registry.keys
      end

      # Get language for file extension (thread-safe)
      def language_for_extension(ext : String) : String?
        extension_map[ext.downcase]?
      end

      # Get all supported extensions (thread-safe)
      def supported_extensions : Array(String)
        extension_map.keys
      end

      # Get preferred installation method for language (thread-safe)
      def preferred_method(language : String) : Symbol?
        info = get_language_info(language)
        info.try(&.preferred_method)
      end

      # Get dependencies for language (thread-safe)
      def dependencies(language : String) : Array(String)
        info = get_language_info(language)
        info.try(&.dependencies) || [] of String
      end

      # Check if language is WASM-based (thread-safe)
      def wasm_language?(language : String) : Bool
        info = get_language_info(language)
        info.try(&.wasm) || false
      end

      # Get package name for language (thread-safe)
      def package_name(language : String) : String?
        info = get_language_info(language)
        info.try(&.package)
      end

      # Get module export name for language (for multi-language packages) (thread-safe)
      def module_export(language : String) : String?
        info = get_language_info(language)
        info.try(&.module_export)
      end

      # Get WASM file name for language (thread-safe)
      def wasm_file(language : String) : String?
        info = get_language_info(language)
        info.try(&.wasm_file)
      end

      # Get extensions for language (thread-safe)
      def extensions_for_language(language : String) : Array(String)
        info = get_language_info(language)
        info.try(&.extensions) || [] of String
      end

      # Find language by package name (thread-safe)
      def language_for_package(package : String) : String?
        registry.each do |language, info|
          return language if info.package == package
        end
        nil
      end

      # Clear cache (useful for testing) - thread-safe
      def clear_cache
        @@mutex.synchronize do
          @@registry = nil
          @@extension_map = nil
          @@initialized = false
        end
      end

      # Register a custom language (thread-safe, for runtime extension)
      def register_language(info : LanguageInfo)
        @@mutex.synchronize do
          ensure_initialized
          updated_registry = registry.dup
          updated_extension_map = extension_map.dup

          updated_registry[info.name] = info
          info.extensions.each do |ext|
            updated_extension_map[ext.downcase] = info.name
          end

          @@registry = updated_registry
          @@extension_map = updated_extension_map
        end
      end

      # Unregister a language (thread-safe)
      def unregister_language(language : String)
        @@mutex.synchronize do
          ensure_initialized
          updated_registry = registry.dup
          updated_extension_map = extension_map.dup

          if info = updated_registry.delete(language)
            info.extensions.each do |ext|
              updated_extension_map.delete(ext.downcase)
            end
          end

          @@registry = updated_registry
          @@extension_map = updated_extension_map
        end
      end

      private def build_extension_map(registry : Hash(String, LanguageInfo)) : Hash(String, String)
        map = {} of String => String

        registry.each do |language, info|
          info.extensions.each do |ext|
            map[ext.downcase] = language
          end
        end

        map
      end

      # Thread-safe class variables
      @@mutex = Mutex.new
      @@initialized = false
      @@registry : Hash(String, LanguageInfo)? = nil
      @@extension_map : Hash(String, String)? = nil
    end
  end
end
