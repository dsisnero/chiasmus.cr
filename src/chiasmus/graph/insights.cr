# Ported from vendor/chiasmus/src/graph/insights.ts
#
# Graph insight detection: hubs (top-degree), bridges (betweenness centrality),
# surprising connections (cross-community + peripheral-to-hub edges).
# Brandes' O(VE) algorithm for betweenness — matches graphology-metrics behavior.

require "./types"
require "./graph_util"
require "./community"

module Chiasmus
  module Graph
    record Hub,
      name : String,
      degree : Int32

    record Bridge,
      name : String,
      score : Float64

    record SurprisingConnection,
      source : String,
      target : String,
      score : Int32,
      reasons : Array(String)

    module Insights
      extend self

      DEFAULT_HUB_TOP_N = 10

      # --- Hubs (top-degree nodes) ---

      def detect_hubs(graph : CodeGraph, top_n : Int32 = DEFAULT_HUB_TOP_N) : Array(Hub)
        degree = GraphUtil.undirected_degree(graph)

        hubs = degree.map { |name, d| Hub.new(name: name, degree: d) }
        hubs.sort! { |a, b|
          cmp = b.degree <=> a.degree
          cmp == 0 ? a.name <=> b.name : cmp
        }
        hubs.first(top_n)
      end

      # --- Bridges (betweenness centrality via Brandes' algorithm) ---

      # Brandes' algorithm for undirected, unweighted graphs.
      # Returns normalized betweenness centrality scores.
      # Outer loop over source nodes is parallelized via spawn + Channel.
      def detect_bridges(graph : CodeGraph) : Array(Bridge)
        nodes = GraphUtil.collect_nodes(graph)
        return [] of Bridge if nodes.empty?

        adj = Hash(String, Set(String)).new
        nodes.each { |n| adj[n] = Set(String).new }
        graph.calls.each do |c|
          next if c.caller == c.callee
          adj[c.caller] << c.callee
          adj[c.callee] << c.caller
        end

        n = nodes.size
        betweenness = Hash(String, Float64).new(0.0)

        if nodes.size < 4
          # Small graph: skip parallelism overhead
          nodes.each do |s|
            local_betweenness = brandes_bfs(s, nodes, adj, n)
            local_betweenness.each { |k, v| betweenness[k] += v }
          end
        else
          # Parallel BFS from each source node
          chan = Channel({Int32, Hash(String, Float64)}).new(nodes.size)
          nodes.each_with_index do |s, idx|
            spawn do
              local = brandes_bfs(s, nodes, adj, n)
              chan.send({idx, local})
            end
          end

          nodes.size.times do
            _, local = chan.receive
            local.each { |k, v| betweenness[k] += v }
          end
        end

        normalize_betweenness(betweenness, n)

        bridges = betweenness
          .select { |_, score| score > 0.0 }
          .map { |name, score| Bridge.new(name: name, score: score) }

        bridges.sort! { |a, b|
          cmp = b.score <=> a.score
          cmp == 0 ? a.name <=> b.name : cmp
        }

        bridges.first(3)
      end

      # BFS from a single source node — returns local betweenness contributions.
      # Pure function, no shared state.
      def brandes_bfs(
        s : String,
        nodes : Set(String),
        adj : Hash(String, Set(String)),
        n : Int32,
      ) : Hash(String, Float64)
        stack = [] of String
        pred = Hash(String, Array(String)).new { |h, k| h[k] = [] of String }
        sigma = Hash(String, Int32).new(0)
        sigma[s] = 1
        dist = Hash(String, Int32).new(-1)
        dist[s] = 0
        queue = [s]

        while !queue.empty?
          v = queue.shift
          stack << v
          adj[v].each do |w|
            if dist[w] < 0
              queue << w
              dist[w] = dist[v] + 1
            end
            if dist[w] == dist[v] + 1
              sigma[w] += sigma[v]
              pred[w] << v
            end
          end
        end

        delta = Hash(String, Float64).new(0.0)
        while !stack.empty?
          w = stack.pop
          pred[w].each do |v|
            delta[v] += (sigma[v].to_f64 / sigma[w]) * (1.0 + delta[w])
          end
          delta[w] += 0.0 unless w == s # ensures entry
        end
        # Remove self-contribution
        delta.delete(s) if delta.has_key?(s)

        delta
      end

      private def normalize_betweenness(betweenness : Hash(String, Float64), n : Int32) : Nil
        betweenness.transform_values! { |v| v / 2.0 }
        if n > 2
          factor = (n - 1) * (n - 2)
          betweenness.transform_values! { |v| v / factor }
        end
      end

      # --- Surprising connections ---

      def detect_surprises(
        graph : CodeGraph,
        communities : Array(Community)? = nil,
        top_n : Int32 = 10,
      ) : Array(SurprisingConnection)
        if communities
          comms = communities
          degree = GraphUtil.undirected_degree(graph)
        else
          # Run community detection and degree calculation concurrently
          comm_chan = Channel(Array(Community)).new(1)
          deg_chan = Channel(Hash(String, Int32)).new(1)
          spawn { comm_chan.send(CommunityDetection.detect(graph)) }
          spawn { deg_chan.send(GraphUtil.undirected_degree(graph)) }
          comms = comm_chan.receive
          degree = deg_chan.receive
        end

        node_to_community = Hash(String, Int32).new
        comms.each { |c| c.members.each { |m| node_to_community[m] = c.id } }

        candidates = [] of SurprisingConnection

        GraphUtil.for_each_undirected_edge(graph) do |a, b|
          score = 0
          reasons = [] of String

          ca = node_to_community[a]?
          cb = node_to_community[b]?
          if ca && cb && ca != cb
            score += 1
            reasons << "cross-community"
          end

          da = degree[a]? || 0
          db = degree[b]? || 0
          if Math.min(da, db) <= 2 && Math.max(da, db) >= 5
            score += 1
            reasons << "peripheral-to-hub"
          end

          if score > 0
            candidates << SurprisingConnection.new(
              source: a,
              target: b,
              score: score,
              reasons: reasons,
            )
          end
        end

        candidates.sort! { |x, y|
          cmp = y.score <=> x.score
          if cmp == 0
            cmp = x.source <=> y.source
            cmp = x.target <=> y.target if cmp == 0
          end
          cmp
        }

        candidates.first(top_n)
      end
    end
  end
end
