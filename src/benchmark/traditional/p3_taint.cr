module Benchmark
  module Traditional
    record TaintResult, reachable : Array({source: String, sink: String}), unreachable : Array(String)

    def self.solve_taint(input : NamedTuple(
                           edges: Array(NamedTuple(from: String, to: String)),
                           sources: Array(String),
                           sinks: Array(String),
                         )) : TaintResult
      adj = Hash(String, Array(String)).new { |hash, key| hash[key] = [] of String }
      input[:edges].each do |edge|
        adj[edge[:from]] << edge[:to]
      end

      reachable_from = ->(start : String) : Set(String) do
        visited = Set(String).new
        queue = [start]
        while queue.size > 0
          node = queue.shift
          next if visited.includes?(node)
          visited.add(node)
          adj[node].each { |next_node| queue << next_node }
        end
        visited
      end

      reachable = [] of {source: String, sink: String}
      unreachable = [] of String

      input[:sources].each do |source|
        reached = reachable_from.call(source)
        input[:sinks].each do |sink|
          if reached.includes?(sink)
            reachable << {source: source, sink: sink}
          else
            unreachable << sink
          end
        end
      end

      TaintResult.new(reachable: reachable, unreachable: unreachable)
    end
  end
end
