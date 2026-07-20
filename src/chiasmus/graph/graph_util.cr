# Ported from vendor/chiasmus/src/graph/graph-util.ts
#
# Shared helpers for building/iterating an undirected view of the call graph.
# Used by community detection, hubs, bridges, and surprising-connection scoring.

require "./types"

module Chiasmus
  module Graph
    module GraphUtil
      extend self

      # Every node that appears in defines or as a call endpoint.
      def collect_nodes(graph : CodeGraph) : Set(String)
        nodes = Set(String).new
        graph.defines.each { |definition| nodes << definition.name }
        graph.calls.each do |call|
          nodes << call.caller
          nodes << call.callee
        end
        nodes
      end

      # Build an undirected adjacency list from the call relation.
      # Self-loops and duplicate edges are dropped — every unique {A,B} pair
      # becomes one edge.
      def build_undirected_graph(graph : CodeGraph, nodes : Set(String)? = nil) : Hash(String, Set(String))
        g = Hash(String, Set(String)).new
        ns = nodes || collect_nodes(graph)
        ns.each { |node| g[node] = Set(String).new }

        graph.calls.each do |call|
          next if call.caller == call.callee
          next unless g.has_key?(call.caller) && g.has_key?(call.callee)
          next if g[call.caller].includes?(call.callee)
          g[call.caller] << call.callee
          g[call.callee] << call.caller
        end

        g
      end

      # Iterate each undirected edge exactly once.
      def for_each_undirected_edge(graph : CodeGraph, & : String, String ->) : Nil
        seen = Set(String).new
        graph.calls.each do |call|
          next if call.caller == call.callee
          key = if call.caller < call.callee
                  "#{call.caller}|#{call.callee}"
                else
                  "#{call.callee}|#{call.caller}"
                end
          next if seen.includes?(key)
          seen << key
          yield call.caller, call.callee
        end
      end

      # Undirected degree: count of distinct neighbors per node.
      def undirected_degree(graph : CodeGraph) : Hash(String, Int32)
        degree = Hash(String, Int32).new(0)
        for_each_undirected_edge(graph) do |a, b|
          degree[a] += 1
          degree[b] += 1
        end
        degree
      end
    end
  end
end
