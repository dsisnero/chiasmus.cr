require "tree_sitter"

module Chiasmus
  module Graph
    module LanguageLoader
      extend self

      def repository_language_paths : Hash(String, Path)
        TreeSitter::Repository.language_paths
      rescue
        {} of String => Path
      end

      def load_language_from_grammar_path(language : String, grammar_path : String) : TreeSitter::Language?
        grammar_dir = if Dir.exists?(grammar_path)
                        Path.new(grammar_path)
                      else
                        Path.new(File.dirname(grammar_path))
                      end

        ts_language = TreeSitter::Repository.load_shared_object(language, grammar_dir)
        TreeSitter::Language.new(language, ts_language)
      rescue
        nil
      end
    end
  end
end
