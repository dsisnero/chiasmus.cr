require "tree_sitter"

module Chiasmus
  module Discovery
    # Platform-aware grammar shared library loading.
    # Searches registered directories with platform-appropriate extensions.
    module GrammarLoader
      extend self

      @@grammar_directories = [] of String

      def register_grammar_directory(path : String) : Nil
        return unless Dir.exists?(path)
        @@grammar_directories << path unless @@grammar_directories.includes?(path)
      end

      def grammar_directories : Array(String)
        @@grammar_directories
      end

      def tree_sitter_available?(language : String) : Bool
        find_grammar_library(language) != nil
      end

      def find_grammar_library(language : String) : String?
        lib_name = "libtree-sitter-#{language}"

        search_paths = @@grammar_directories.dup
        # Auto-register project vendor/grammars relative to this file
        project_vendor = File.expand_path("../../../vendor/grammars", __DIR__)
        if Dir.exists?(project_vendor) && !search_paths.includes?(project_vendor)
          search_paths << project_vendor
        end

        search_paths.each do |dir|
          next unless Dir.exists?(dir)

          candidate_dirs = [
            File.join(dir, "tree-sitter-#{language}"),
            dir,
          ]

          candidate_dirs.each do |candidate_dir|
            next unless Dir.exists?(candidate_dir)

            ext = shared_library_extension

            # Standard name: libtree-sitter-{lang}.{ext}
            lib_path = File.join(candidate_dir, "#{lib_name}.#{ext}")
            return lib_path if File.exists?(lib_path)

            # Tree-sitter CLI default: {lang}.{ext}
            alt_path = File.join(candidate_dir, "#{language}.#{ext}")
            return alt_path if File.exists?(alt_path)

            # Some versions output: parser.{ext}
            parser_path = File.join(candidate_dir, "parser.#{ext}")
            return parser_path if File.exists?(parser_path)

            # Check subdirectories (e.g., tree-sitter-typescript/typescript/)
            Dir.children(candidate_dir).each do |sub|
              sub_path = File.join(candidate_dir, sub)
              next unless Dir.exists?(sub_path)
              sub_lib = File.join(sub_path, "#{lib_name}.#{ext}")
              return sub_lib if File.exists?(sub_lib)
            end
          end
        end

        nil
      end

      def load_language(language : String) : TreeSitter::Language?
        lib_path = find_grammar_library(language)
        return nil unless lib_path

        handle = LibC.dlopen(lib_path, LibC::RTLD_LAZY | LibC::RTLD_LOCAL)
        return nil if handle.null?

        # Try multiple symbol naming conventions
        symbol_names = [
          "tree_sitter_#{language}",
          "tree_sitter_#{language.downcase}",
          "tree_sitter_#{language.gsub('-', '_')}",
        ]

        ptr = nil
        symbol_names.each do |sym|
          ptr = LibC.dlsym(handle, sym)
          break if ptr
        end

        return nil unless ptr

        lang_ptr = Proc(LibTreeSitter::TSLanguage*).new(ptr, Pointer(Void).null).call
        TreeSitter::Language.new(language, lang_ptr)
      rescue ex
        nil
      end

      private def shared_library_extension : String
        Platform.shared_library_extension
      end
    end
  end
end
