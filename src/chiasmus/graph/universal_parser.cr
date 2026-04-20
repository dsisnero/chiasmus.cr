require "tree_sitter"
require "./parser"
require "./grammar_manager"
require "./language_loader"
require "./async_universal_parser_v2"
require "../utils/xdg"
require "../utils/timeout"

module Chiasmus
  module Graph
    # Universal parser that can handle any language by:
    # 1. Using bundled grammars for common languages
    # 2. Downloading/building grammars on demand
    # 3. Falling back to system-installed grammars
    class UniversalParser
      @@initialized = false
      @@grammar_cache = {} of String => TreeSitter::Language?

      # Initialize the universal parser
      def self.init(cache_dir : String? = nil)
        return if @@initialized

        # Avoid eager filesystem writes here. In sandboxed environments we may be
        # able to parse already-installed grammars, but not create cache/config dirs.
        setup_tree_sitter_config

        # Preload common grammars if available
        preload_common_grammars

        @@initialized = true
      end

      # Parse source code, automatically handling grammar availability
      def self.parse(content : String, file_path : String, timeout_ms : Int32 = 30_000) : TreeSitter::Tree?
        init unless @@initialized
        result_channel = AsyncUniversalParserV2.parse_async(content, file_path, timeout_ms)
        result = Utils::Timeout.with_timeout_async(timeout_ms, result_channel)
        return nil unless result && result.success?

        result.value
      end

      # Get a language, trying multiple sources
      def self.get_language(language : String, timeout_ms : Int32 = 60_000) : TreeSitter::Language?
        init unless @@initialized
        result_channel = AsyncUniversalParserV2.get_language_async(language, timeout_ms)
        result = Utils::Timeout.with_timeout_async(timeout_ms, result_channel)
        return nil unless result && result.success?

        result.value
      end

      # Check if a language is supported (either available or can be built)
      def self.supports_language?(language : String) : Bool
        # Check if it's in our language mapping
        return false unless Parser::EXT_MAP.values.includes?(language)

        # Check if available or can be built
        get_language(language) != nil
      end

      # Get all supported languages (that we can parse)
      def self.supported_languages : Array(String)
        Parser::EXT_MAP.values.uniq!.select do |language|
          supports_language?(language)
        end
      end

      private def self.setup_tree_sitter_config
        # Create tree-sitter config directory if it doesn't exist
        config_dir = tree_sitter_config_dir
        tree_sitter_config_dir = File.join(config_dir, "tree-sitter")
        Dir.mkdir_p(tree_sitter_config_dir)

        config_file = File.join(tree_sitter_config_dir, "config.json")
        unless File.exists?(config_file)
          # Create a config with our vendored grammars directory
          parser_dirs = [File.expand_path("../../../vendor/grammars", __DIR__)]

          # Add standard locations
          {% if flag?(:darwin) %}
            parser_dirs << "/usr/local/lib"
            parser_dirs << "#{ENV["HOME"]}/.local/lib"
          {% else %}
            parser_dirs << "/usr/lib"
            parser_dirs << "/usr/local/lib"
            parser_dirs << "#{ENV["HOME"]}/.local/lib"
          {% end %}

          # Filter to only directories that exist
          parser_dirs = parser_dirs.select { |dir| Dir.exists?(dir) }

          config = {
            "parser-directories" => parser_dirs,
          }

          File.write(config_file, config.to_json)
        end
      rescue File::Error
        # Sandboxed test environments may not allow writes under the home dir.
        # Parsing can still succeed with already-installed grammars, so continue.
      end

      private def self.tree_sitter_config_dir : String
        Utils::XDG.tree_sitter_config_dir
      end

      private def self.preload_common_grammars
        # Try to preload common grammars
        common_languages = ["crystal", "python", "javascript", "typescript", "rust", "go"]

        common_languages.each do |lang|
          preload_system_language(lang)
        end
      end

      private def self.preload_system_language(language : String)
        language_paths = LanguageLoader.repository_language_paths
        if path = language_paths[language]?
          if lang = TreeSitter::Repository.load_language?(language, path)
            @@grammar_cache[language] = lang
          end
        end
      rescue
        nil
      end
    end
  end
end
