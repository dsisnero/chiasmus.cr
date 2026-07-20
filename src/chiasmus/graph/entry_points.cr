# Ported from vendor/chiasmus/src/graph/entry-points.ts
#
# Heuristic entry-point detection for dead-code analysis.
# Prefers zero-in-degree exports, falls back to all exports, then
# zero-in-degree functions. Methods are excluded (dynamically dispatched).

require "./types"

module Chiasmus
  module Graph
    module EntryPoints
      extend self

      def detect(graph : CodeGraph) : Array(String)
        called = Set(String).new
        graph.calls.each { |call| called << call.callee }

        method_names = Set(String).new
        function_names = Set(String).new
        graph.defines.each do |definition|
          if definition.kind.method?
            method_names << definition.name
          elsif definition.kind.function?
            function_names << definition.name
          end
        end

        exported_fns = graph.exports
          .map(&.name)
          .reject { |function_name| method_names.includes?(function_name) }

        if !exported_fns.empty?
          zero_indegree = exported_fns.reject { |function_name| called.includes?(function_name) }
          return zero_indegree.uniq!.sort! unless zero_indegree.empty?
          return exported_fns.uniq!.sort!
        end

        roots = function_names.reject { |function_name| called.includes?(function_name) }
        roots.to_a.uniq!.sort!
      end
    end
  end
end
