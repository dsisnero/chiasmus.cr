require "./language_registry"
require "./adapter_registry"

module Chiasmus
  module Graph
    module Parser
      record ParseArtifact,
        tree : TreeSitter::Tree?

      record ParseOutcome,
        tree : TreeSitter::Tree? = nil,
        error : String? = nil,
        details : Hash(String, String) = {} of String => String do
        def success? : Bool
          error.nil?
        end
      end

      class LanguageResolver
        def language_for_file(file_path : String) : String?
          ext = normalized_extension(file_path)
          if built_in = LanguageRegistry.language_for_extension(ext)
            return built_in
          end

          AdapterRegistry.language_for_ext(ext)
        end

        def grammar_language_for_file(file_path : String) : String?
          ext = normalized_extension(file_path)
          if built_in = LanguageRegistry.language_for_extension(ext)
            return built_in
          end

          AdapterRegistry.grammar_language_for_ext(ext)
        end

        def supported_extensions : Array(String)
          (LanguageRegistry.supported_extensions + AdapterRegistry.adapter_extensions).uniq.sort!
        end

        def supported_languages : Array(String)
          adapter_languages = AdapterRegistry.adapter_extensions.compact_map do |ext|
            AdapterRegistry.get_adapter_for_ext(ext).try(&.language)
          end
          (LanguageRegistry.supported_languages + adapter_languages).uniq
        end

        def known_language?(language : String) : Bool
          !!LanguageRegistry.get_language_info(language) || !!AdapterRegistry.get_adapter(language)
        end

        private def normalized_extension(file_path : String) : String
          File.extname(file_path).downcase
        end
      end
    end
  end
end
