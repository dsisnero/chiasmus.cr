# Ported from vendor/chiasmus/src/graph/insights.ts
#
# Graph insight detection: hubs (top-degree nodes).
# Bridges and surprising connections require external npm packages
# (graphology-metrics betweenness, Louvain) — not ported.

require "./types"
require "./graph_util"

module Chiasmus
  module Graph
    record Hub,
      name : String,
      degree : Int32

    module Insights
      extend self

      DEFAULT_HUB_TOP_N = 10

      def detect_hubs(graph : CodeGraph, top_n : Int32 = DEFAULT_HUB_TOP_N) : Array(Hub)
        degree = GraphUtil.undirected_degree(graph)

        hubs = degree.map { |name, d| Hub.new(name: name, degree: d) }
        hubs.sort! { |a, b|
          cmp = b.degree <=> a.degree
          cmp == 0 ? a.name <=> b.name : cmp
        }
        hubs.first(top_n)
      end
    end
  end
end
