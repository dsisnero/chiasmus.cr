require "./parser"

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
            partial.calls.each do |c|
              key = "#{c.caller}->#{c.callee}"
              unless call_set.includes?(key)
                call_set.add(key)
                calls << c
              end
            end
            imports.concat(partial.imports)
            exports.concat(partial.exports)
            contains.concat(partial.contains)
          else
            # For now, we don't have language-specific walkers implemented
            # This is a placeholder for future implementation
            # TODO: Implement language-specific walkers
            nil
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
        # TODO: Implement adapter registry
        nil
      end
    end
  end
end
