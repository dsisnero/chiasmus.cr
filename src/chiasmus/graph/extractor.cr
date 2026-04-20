require "./parser"
require "./walkers"

module Chiasmus
  module Graph
    record SourceFile, path : String, content : String

    module Extractor
      extend self

      def extract_graph(files : Array(SourceFile)) : CodeGraph
        defines = [] of DefinesFact
        calls = [] of CallsFact
        imports = [] of ImportsFact
        exports = [] of ExportsFact
        contains = [] of ContainsFact

        call_set = Set(String).new # deduplicate caller→callee

        files.each do |file|
          lang = Parser.get_language_for_file(file.path)
          next unless lang

          # Try to parse the file
          tree = Parser.parse_source(file.content, file.path)
          next unless tree

          # Check for a registered adapter first
          adapter = get_adapter(lang)
          if adapter
            partial = adapter.extract(tree.root_node, file.path)
            defines.concat(partial.defines)
            partial.calls.each do |call_fact|
              key = "#{call_fact.caller}->#{call_fact.callee}"
              unless call_set.includes?(key)
                call_set.add(key)
                calls << call_fact
              end
            end
            imports.concat(partial.imports)
            exports.concat(partial.exports)
            contains.concat(partial.contains)
          else
            # Use language-specific walkers
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
              # Generic walker for JavaScript/TypeScript and other languages
              Walkers.walk_node(tree.root_node, file.content, file.path, lang, scope_stack, defines, calls, imports, exports, contains, call_set)
            end
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

      private def get_adapter(language : String) : LanguageAdapter?
        # Adapter registry integration is still pending.
        nil
      end
    end
  end
end
