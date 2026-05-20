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
        graph.defines.each { |d| nodes << d.name }
        graph.calls.each do |c|
          nodes << c.caller
          nodes << c.callee
        end
        nodes
      end

      # Build an undirected adjacency list from the call relation.
      # Self-loops and duplicate edges are dropped — every unique {A,B} pair
      # becomes one edge.
      def build_undirected_graph(graph : CodeGraph, nodes : Set(String)? = nil) : Hash(String, Set(String))
        g = Hash(String, Set(String)).new
        ns = nodes || collect_nodes(graph)
        ns.each { |n| g[n] = Set(String).new }

        graph.calls.each do |c|
          next if c.caller == c.callee
          next unless g.has_key?(c.caller) && g.has_key?(c.callee)
          next if g[c.caller].includes?(c.callee)
          g[c.caller] << c.callee
          g[c.callee] << c.caller
        end

        g
      end

      # Iterate each undirected edge exactly once.
      def for_each_undirected_edge(graph : CodeGraph, & : String, String ->) : Nil
        seen = Set(String).new
        graph.calls.each do |c|
          next if c.caller == c.callee
          key = if c.caller < c.callee
                  "#{c.caller}|#{c.callee}"
                else
                  "#{c.callee}|#{c.caller}"
                end
          next if seen.includes?(key)
          seen << key
          yield c.caller, c.callee
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
