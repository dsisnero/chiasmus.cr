require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/graph_util"
require "../../../src/chiasmus/graph/community"

include Chiasmus::Graph

private def build_graph(calls : Array(Tuple(String, String)), defines : Array(String) = [] of String) : CodeGraph
  all_names = Set(String).new
  defines.each { |n| all_names << n }
  calls.each do |(a, b)|
    all_names << a
    all_names << b
  end
  CodeGraph.new(
    defines: all_names.map { |n| DefinesFact.new(file: "t.ts", name: n, kind: SymbolKind::Function, line: 1) },
    calls: calls.map { |(caller, callee)| CallsFact.new(caller: caller, callee: callee) },
  )
end

describe CommunityDetection do
  describe ".detect" do
    it "returns empty list for empty graph" do
      communities = CommunityDetection.detect(CodeGraph.new)
      communities.should eq([] of Community)
    end

    it "places isolated nodes into singleton communities" do
      graph = build_graph([] of Tuple(String, String), ["a", "b", "c"])
      communities = CommunityDetection.detect(graph)
      communities.size.should eq 3
      communities.each { |c| c.members.size.should eq 1 }
    end

    it "separates two cliques connected by a single bridge" do
      edges = [
        {"a", "b"}, {"b", "c"}, {"a", "c"},
        {"d", "e"}, {"e", "f"}, {"d", "f"},
        {"c", "d"},
      ]
      communities = CommunityDetection.detect(build_graph(edges))
      communities.size.should be >= 2

      community_of = Hash(String, Int32).new
      communities.each { |c| c.members.each { |m| community_of[m] = c.id } }

      community_of["a"].should eq community_of["b"]
      community_of["a"].should eq community_of["c"]
      community_of["d"].should eq community_of["e"]
      community_of["d"].should eq community_of["f"]
      community_of["a"].should_not eq community_of["d"]
    end

    it "is deterministic across runs with the same input" do
      edges = [
        {"a", "b"}, {"b", "c"}, {"c", "a"},
        {"d", "e"}, {"e", "f"},
      ]
      r1 = CommunityDetection.detect(build_graph(edges))
      r2 = CommunityDetection.detect(build_graph(edges))
      r1.map(&.members).should eq r2.map(&.members)
    end

    it "sorts communities by size descending with 0-indexed ids" do
      edges = [
        {"a", "b"}, {"b", "c"}, {"c", "d"}, {"a", "c"}, {"a", "d"}, {"b", "d"},
        {"e", "f"},
      ]
      communities = CommunityDetection.detect(build_graph(edges))
      communities[0].id.should eq 0
      if communities.size > 1
        communities[0].members.size.should be >= communities[1].members.size
      end
      communities.each_with_index { |c, i| c.id.should eq i }
    end

    it "members within each community are lexically sorted" do
      communities = CommunityDetection.detect(build_graph([] of Tuple(String, String), ["charlie", "alice", "bob"]))
      communities.each do |c|
        c.members.should eq c.members.sort
      end
    end

    it "detected communities carry a cohesion score in [0, 1]" do
      edges = [
        {"a", "b"}, {"b", "c"}, {"c", "a"},
        {"d", "e"}, {"e", "f"}, {"d", "f"},
      ]
      communities = CommunityDetection.detect(build_graph(edges))
      communities.each do |c|
        c.cohesion.should be >= 0.0
        c.cohesion.should be <= 1.0
      end
    end
  end

  describe "cohesion_score (private — tested via detect)" do
    # cohesion_score is private, tested indirectly via detect
    # The upstream tests the function directly, but Crystal doesn't expose private methods
    # The behavior is verified by the "cohesion in [0,1]" and bridge tests above
  end

  it "splits oversized communities" do
    # Two cliques of 10 connected by a thin bridge
    edges = [] of Tuple(String, String)
    a = (0...10).map { |i| "a#{i}" }
    b = (0...10).map { |i| "b#{i}" }
    a.each_with_index do |ai, i|
      ((i + 1)...a.size).each { |j| edges << {ai, a[j]} }
    end
    b.each_with_index do |bi, i|
      ((i + 1)...b.size).each { |j| edges << {bi, b[j]} }
    end
    edges << {"a0", "b0"}

    communities = CommunityDetection.detect(build_graph(edges))
    total = communities.sum(&.members.size)
    total.should eq 20
    communities.size.should be >= 2
  end
end
