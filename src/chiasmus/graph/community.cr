# Louvain community detection with deterministic seeded PRNG (mulberry32).
# Ported from vendor/chiasmus/src/graph/community.ts — replaces graphology-communities-louvain npm dep.

require "./types"
require "./graph_util"

module Chiasmus
  module Graph
    record Community,
      id : Int32,
      members : Array(String),
      cohesion : Float64

    module CommunityDetection
      extend self

      private DEFAULT_SEED = 42

      # mulberry32 PRNG — deterministic, seeded. Implements Crystal's Random interface.
      class Mulberry32
        include Random

        @state : UInt32

        def initialize(@state : UInt32)
        end

        def self.new(seed : Int32)
          new(seed.to_u32)
        end

        def next_u : UInt32
          @state = @state &+ 0x6d2b79f5_u32
          t = @state
          t = (t ^ (t >> 15)) &* (t | 1)
          t = t ^ (t &+ (t ^ (t >> 7)) &* (t | 61))
          t = t ^ (t >> 14)
          t
        end
      end

      private def cohesion_score(member_count : Int32, intra_edges : Int32) : Float64
        return 0.0 if member_count < 2
        max = member_count * (member_count - 1) // 2
        ratio = intra_edges.to_f64 / max
        ((ratio * 100).round) / 100.0
      end

      # Build weighted adjacency from CodeGraph calls
      private def build_adjacency(graph : CodeGraph, nodes : Set(String)) : Hash(String, Hash(String, Float64))
        adj = Hash(String, Hash(String, Float64)).new
        nodes.each { |n| adj[n] = Hash(String, Float64).new(0.0) }
        graph.calls.each do |c|
          next if c.caller == c.callee
          next unless nodes.includes?(c.caller) && nodes.includes?(c.callee)
          adj[c.caller][c.callee] += 1.0
          adj[c.callee][c.caller] += 1.0
        end
        adj
      end

      # Louvain phase 1: one pass of modularity optimization
      private def louvain_phase1(
        adj : Hash(String, Hash(String, Float64)),
        communities : Hash(String, Int32),
        total_weight : Float64,
        rng : Random,
      ) : Bool
        nodes = adj.keys.to_a
        return false if total_weight == 0.0

        node_weight = Hash(String, Float64).new(0.0)
        adj.each { |u, nbrs| node_weight[u] = nbrs.values.sum }

        comm_weight = Hash(Int32, Float64).new(0.0)
        communities.each { |u, c| comm_weight[c] = comm_weight[c] + node_weight[u] }

        changed = false
        shuffled = nodes.shuffle(rng)
        two_m = total_weight

        shuffled.each do |u|
          u_comm = communities[u]
          k_i = node_weight[u]

          neighbor_comms = Hash(Int32, Float64).new(0.0)
          adj[u].each { |v, w| neighbor_comms[communities[v]] += w }

          best_comm = u_comm
          best_gain = 0.0

          neighbor_comms.each do |c, k_i_in_c|
            next if c == u_comm

            sigma_in_c = comm_weight[c]? || 0.0
            sigma_in_u = comm_weight[u_comm]? || 0.0
            k_i_in_u = neighbor_comms[u_comm]? || 0.0

            # Standard Louvain modularity gain for moving node i from u_comm to c
            gain = (k_i_in_c - k_i_in_u) / two_m
            gain -= k_i * (sigma_in_c - (sigma_in_u - k_i)) / (two_m * two_m)

            if gain > best_gain
              best_gain = gain
              best_comm = c
            end
          end

          if best_comm != u_comm
            comm_weight[u_comm] -= k_i
            comm_weight[best_comm] += k_i
            communities[u] = best_comm
            changed = true
          end
        end

        changed
      end

      # Main entry point: detect communities via Louvain algorithm
      def detect(graph : CodeGraph, seed : Int32 = DEFAULT_SEED) : Array(Community)
        rng = Mulberry32.new(seed)
        nodes = GraphUtil.collect_nodes(graph)
        return [] of Community if nodes.empty?

        adj = build_adjacency(graph, nodes)
        total_weight = adj.values.sum(0.0) { |nbrs| nbrs.values.sum }

        # Initialize each node in own community
        communities = Hash(String, Int32).new
        nodes.each_with_index { |n, i| communities[n] = i }

        # Run phase 1 repeatedly until convergence
        100.times do
          break unless louvain_phase1(adj, communities, total_weight, rng)
        end

        # Group by community
        by_comm = Hash(Int32, Array(String)).new { |h, k| h[k] = [] of String }
        communities.each { |n, c| by_comm[c] << n }

        # Build community-to-id mapping for intra-edge counting
        comm_ids = Hash(String, Int32).new
        by_comm.each { |cid, members| members.each { |m| comm_ids[m] = cid } }

        # Count intra-community edges for cohesion
        intra_counts = Hash(Int32, Int32).new(0)
        adj.each do |u, neighbors|
          neighbors.each do |v, w|
            next unless u < v # count each undirected edge once
            intra_counts[comm_ids[u]] += w.to_i if comm_ids[u] == comm_ids[v]
          end
        end

        # Sort by descending size, lexical tiebreak
        sorted = by_comm.to_a.sort_by { |_, members| {-members.size, members.first? || ""} }

        sorted.map_with_index do |(cid, members), idx|
          cohesion = cohesion_score(members.size, intra_counts[cid]? || 0)
          Community.new(id: idx, members: members.sort, cohesion: cohesion)
        end
      end
    end
  end
end
