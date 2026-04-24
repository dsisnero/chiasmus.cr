require "./parser"
require "./walkers"
require "./adapter_registry"

module Chiasmus
  module Graph
    record SourceFile, path : String, content : String

    module Extractor
      extend self

      def extract_graph(files : Array(SourceFile), parser = Parser) : CodeGraph
        defines = [] of DefinesFact
        calls = [] of CallsFact
        imports = [] of ImportsFact
        exports = [] of ExportsFact
        contains = [] of ContainsFact

        call_set = Set(String).new

        files.each do |file|
          lang = parser.language_for_file(file.path)
          next unless lang

          tree = parser.parse_source(file.content, file.path)
          next unless tree

          adapter = AdapterRegistry.get_adapter(lang)
          if adapter
            merge_adapter_graph(
              adapter.extract(tree.root_node, file.content, file.path),
              defines,
              calls,
              imports,
              exports,
              contains,
              call_set
            )
          else
            extract_with_walkers(
              lang,
              tree,
              file,
              defines,
              calls,
              imports,
              exports,
              contains,
              call_set
            )
          end
        end

        CodeGraph.new(
          defines: defines,
          calls: calls,
          imports: imports,
          exports: exports,
          contains: contains
        )
      end

      private def merge_adapter_graph(
        partial : CodeGraph,
        defines : Array(DefinesFact),
        calls : Array(CallsFact),
        imports : Array(ImportsFact),
        exports : Array(ExportsFact),
        contains : Array(ContainsFact),
        call_set : Set(String),
      ) : Nil
        defines.concat(partial.defines)
        partial.calls.each do |call_fact|
          key = "#{call_fact.caller}->#{call_fact.callee}"
          next if call_set.includes?(key)

          call_set.add(key)
          calls << call_fact
        end
        imports.concat(partial.imports)
        exports.concat(partial.exports)
        contains.concat(partial.contains)
      end

      private def extract_with_walkers(
        lang : String,
        tree : TreeSitter::Tree,
        file : SourceFile,
        defines : Array(DefinesFact),
        calls : Array(CallsFact),
        imports : Array(ImportsFact),
        exports : Array(ExportsFact),
        contains : Array(ContainsFact),
        call_set : Set(String),
      ) : Nil
        scope_stack = [] of String
        case lang
        when "clojure"
          Walkers.walk_clojure(tree.root_node, file.content, file.path, defines, calls, imports, exports, call_set)
        when "python"
          Walkers.walk_python(tree.root_node, file.content, file.path, scope_stack, defines, calls, imports, exports, contains, call_set)
        when "go"
          Walkers.walk_go(tree.root_node, file.content, file.path, defines, calls, imports, exports, contains, call_set)
        when "crystal"
          Walkers.walk_crystal(tree.root_node, file.content, file.path, scope_stack, defines, calls, imports, exports, contains, call_set)
        else
          Walkers.walk_node(tree.root_node, file.content, file.path, lang, scope_stack, defines, calls, imports, exports, contains, call_set)
        end
      end
    end
  end
end
