require "tree_sitter"
require "lib_c"

module Chiasmus
  module Graph
    module LanguageLoader
      extend self

      def repository_language_paths : Hash(String, Path)
        TreeSitter::Repository.language_paths
      rescue
        {} of String => Path
      end

      def load_language_from_grammar_path(language : String, grammar_path : String?) : TreeSitter::Language?
        # C# tree-sitter: symbol is tree_sitter_c_sharp, file is libtree-sitter-csharp
        if language == "csharp"
          ts_name = "c_sharp"
          # Use repo root as base for vendor directory resolution
          repo_root = Path[__DIR__].join("../../..").expand
          vendor_path = repo_root.join("vendor/grammars/tree-sitter-c-sharp").to_s
          vendor_dir = Path.new(vendor_path)
          if Dir.exists?(vendor_path)
            ts_language = load_dylib(ts_name, vendor_dir)
            return TreeSitter::Language.new(language, ts_language)
          end
        end

        # C++ tree-sitter grammar at vendor/grammars/tree-sitter-cpp
        if language == "cpp"
          repo_root = Path[__DIR__].join("../../..").expand
          vendor_path = repo_root.join("vendor/grammars/tree-sitter-cpp").to_s
          vendor_dir = Path.new(vendor_path)
          if Dir.exists?(vendor_path)
            ts_language = load_dylib(language, vendor_dir)
            return TreeSitter::Language.new(language, ts_language)
          end
        end

        if grammar_path && !grammar_path.empty?
          grammar_dir = Dir.exists?(grammar_path) ? Path.new(grammar_path) : Path.new(File.dirname(grammar_path))
          ts_language = TreeSitter::Repository.load_shared_object(language, grammar_dir)
          return TreeSitter::Language.new(language, ts_language)
        end

        nil
      rescue
        nil
      end

      private def load_dylib(symbol_name : String, language_path : Path)
        file_extension = {% if flag?(:darwin) %}
                           "dylib"
                         {% else %}
                           "so"
                         {% end %}

        # Try exact name first, then without prefix
        so_path = language_path.join("libtree-sitter-#{symbol_name}.#{file_extension}")
        unless File.exists?(so_path.to_s)
          # C# case: file is libtree-sitter-csharp.dylib but symbol is c_sharp
          alt_name = symbol_name == "c_sharp" ? "csharp" : symbol_name
          so_path = language_path.join("libtree-sitter-#{alt_name}.#{file_extension}")
        end

        raise "Missing grammar: #{so_path}" unless File.exists?(so_path.to_s)

        handle = LibC.dlopen(so_path.to_s, LibC::RTLD_LAZY | LibC::RTLD_LOCAL)
        raise "Cannot load grammar: #{so_path}" if handle.null?

        ptr = LibC.dlsym(handle, "tree_sitter_#{symbol_name}")
        raise "Missing symbol tree_sitter_#{symbol_name} in #{so_path}" unless ptr

        Proc(LibTreeSitter::TSLanguage*).new(ptr, Pointer(Void).null).call
      end
    end
  end
end
