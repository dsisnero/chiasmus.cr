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
        graph.calls.each { |c| called << c.callee }

        method_names = Set(String).new
        function_names = Set(String).new
        graph.defines.each do |d|
          if d.kind.method?
            method_names << d.name
          elsif d.kind.function?
            function_names << d.name
          end
        end

        exported_fns = graph.exports
          .map(&.name)
          .reject { |n| method_names.includes?(n) }

        if !exported_fns.empty?
          zero_indegree = exported_fns.reject { |n| called.includes?(n) }
          return zero_indegree.uniq!.sort! unless zero_indegree.empty?
          return exported_fns.uniq!.sort!
        end

        roots = function_names.reject { |n| called.includes?(n) }
        roots.to_a.uniq!.sort!
      end
    end
  end
end
