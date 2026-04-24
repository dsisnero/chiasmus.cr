require "tree_sitter"
require "./types"
require "./parser_environment"
require "./parser_language_resolver"
require "./parser_service"

module Chiasmus
  module Graph
    module Parser
      extend self

      @@service = Service.new

      def service : Service
        @@service
      end

      def service=(service : Service) : Service
        @@service = service
      end

      def init(cache_dir : String? = nil) : Nil
        service.init(cache_dir)
      end

      def get_language_for_file(file_path : String) : String?
        service.get_language_for_file(file_path)
      end

      def language_for_file(file_path : String) : String?
        get_language_for_file(file_path)
      end

      def grammar_language_for_file(file_path : String) : String?
        service.grammar_language_for_file(file_path)
      end

      def supported_extensions : Array(String)
        service.supported_extensions
      end

      def parse_async(content : String, file_path : String, timeout_ms : Int32 = 30_000) : Channel(Utils::Result(ParseArtifact))
        service.parse_async(content, file_path, timeout_ms)
      end

      def parse_source_async(content : String, file_path : String, timeout_ms : Int32 = 30_000) : Channel(Utils::Result(ParseArtifact))
        service.parse_async(content, file_path, timeout_ms)
      end

      def parse(content : String, file_path : String, timeout_ms : Int32 = 30_000) : TreeSitter::Tree?
        service.parse(content, file_path, timeout_ms)
      end

      def parse_source(content : String, file_path : String, timeout_ms : Int32 = 30_000) : TreeSitter::Tree?
        service.parse(content, file_path, timeout_ms)
      end

      def get_language_async(language : String, timeout_ms : Int32 = 60_000) : Channel(Utils::Result(TreeSitter::Language?))
        service.get_language_async(language, timeout_ms)
      end

      def get_language(language : String, timeout_ms : Int32 = 60_000) : TreeSitter::Language?
        service.get_language(language, timeout_ms)
      end

      def supports_language_async?(language : String) : Channel(Bool)
        service.supports_language_async?(language)
      end

      def supports_language?(language : String) : Bool
        service.supports_language?(language)
      end

      def supported_languages_async : Channel(Array(String))
        service.supported_languages_async
      end

      def supported_languages : Array(String)
        service.supported_languages
      end

      def clear_cache : Nil
        service.clear_cache
      end

      def shutdown : Nil
        service.shutdown
      end

      def reset_service : Nil
        @@service = Service.new
      end
    end
  end
end
