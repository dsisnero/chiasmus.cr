require "tree_sitter"
require "./types"
require "./universal_parser"
require "./async_universal_parser_v2"
require "./language_registry"
require "../utils/timeout"

module Chiasmus
  module Graph
    module Parser
      extend self

      # Delegate to LanguageRegistry for language metadata
      # Following Dependency Inversion Principle - depends on abstraction

      # Get the tree-sitter language name for a file path
      def get_language_for_file(file_path : String) : String?
        ext = File.extname(file_path).downcase
        # Use LanguageRegistry for extension mapping
        LanguageRegistry.language_for_extension(ext) || get_adapter_for_ext(ext).try(&.language)
      end

      # Get all supported file extensions
      def supported_extensions : Array(String)
        LanguageRegistry.supported_extensions + get_adapter_extensions
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
        # Check if language is in LanguageRegistry
        info = LanguageRegistry.get_language_info(language)
        return nil unless info

        # For WASM languages (like Clojure), we can't load them synchronously
        # in the same way as native tree-sitter grammars
        if info.wasm
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
