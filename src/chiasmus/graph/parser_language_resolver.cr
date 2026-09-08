require "tree-sitter-manager"
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
        SEXP_EXTENSIONS = {
          "scm"  => {"scheme", "scheme"},
          "ss"   => {"scheme", "scheme"},
          "sld"  => {"scheme", "scheme"},
          "sls"  => {"scheme", "scheme"},
          "sps"  => {"scheme", "scheme"},
          "rkt"  => {"racket", "scheme"},
          "lisp" => {"commonlisp", "commonlisp"},
          "lsp"  => {"commonlisp", "commonlisp"},
          "cl"   => {"commonlisp", "commonlisp"},
          "asd"  => {"commonlisp", "commonlisp"},
        }

        def language_for_file(file_path : String) : String?
          ext = normalized_extension(file_path)
          return SEXP_EXTENSIONS[ext][0] if SEXP_EXTENSIONS.has_key?(ext)
          if built_in = TreeSitterManager::LanguageRegistry.language_for_extension(ext)
            return built_in
          end

          AdapterRegistry.language_for_ext(ext)
        end

        def grammar_language_for_file(file_path : String) : String?
          ext = normalized_extension(file_path)
          return SEXP_EXTENSIONS[ext][1] if SEXP_EXTENSIONS.has_key?(ext)
          if built_in = TreeSitterManager::LanguageRegistry.language_for_extension(ext)
            return built_in
          end

          AdapterRegistry.grammar_language_for_ext(ext)
        end

        def supported_extensions : Array(String)
          bare_exts = TreeSitterManager::LanguageRegistry.supported_extensions.map { |e| e.starts_with?('.') ? e : ".#{e}" }
          (bare_exts + AdapterRegistry.adapter_extensions + SEXP_EXTENSIONS.keys.map { |ext| ".#{ext}" }).uniq.sort!
        end

        def supported_languages : Array(String)
          adapter_languages = AdapterRegistry.adapter_extensions.compact_map do |ext|
            AdapterRegistry.get_adapter_for_ext(ext).try(&.language)
          end
          (TreeSitterManager::LanguageRegistry.supported_languages + adapter_languages + ["scheme", "racket", "commonlisp"]).uniq
        end

        def known_language?(language : String) : Bool
          SEXP_EXTENSIONS.values.any? { |logical, grammar| language == logical || language == grammar } ||
            !!TreeSitterManager::LanguageRegistry.get_language_info(language) || !!AdapterRegistry.get_adapter(language)
        end

        private def normalized_extension(file_path : String) : String
          File.extname(file_path).lstrip('.').downcase
        end
      end
    end
  end
end
