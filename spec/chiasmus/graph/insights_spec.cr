require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/graph_util"
require "../../../src/chiasmus/graph/insights"

include Chiasmus::Graph

private def build_graph(calls : Array(Tuple(String, String))) : CodeGraph
  names = Set(String).new
  calls.each { |(a, b)| names << a; names << b }
  CodeGraph.new(
    defines: names.map { |n| DefinesFact.new(file: "t.ts", name: n, kind: SymbolKind::Function, line: 1) },
    calls: calls.map { |(caller, callee)| CallsFact.new(caller: caller, callee: callee) },
  )
end

describe Insights do
  describe ".detect_hubs" do
    it "returns empty list for empty graph" do
      hubs = Insights.detect_hubs(CodeGraph.new)
      hubs.should eq [] of Hub
    end

    it "ranks by total degree (in + out)" do
      edges = [
        {"a", "center"}, {"b", "center"}, {"c", "center"},
        {"center", "d"}, {"center", "e"},
      ]
      hubs = Insights.detect_hubs(build_graph(edges))
      hubs[0].name.should eq "center"
      hubs[0].degree.should eq 5
    end

    it "respects topN option" do
      edges = (0...20).map { |i| {"caller#{i}", "target"} }
      hubs = Insights.detect_hubs(build_graph(edges), top_n: 5)
      hubs.size.should be <= 5
    end

    it "default topN is 10" do
      edges = (0...15).map { |i| {"a#{i}", "b#{i}"} }
      hubs = Insights.detect_hubs(build_graph(edges))
      hubs.size.should be <= 10
    end

    it "ties broken lexically for determinism" do
      edges = [
        {"x", "zebra"}, {"y", "zebra"},
        {"x", "apple"}, {"y", "apple"},
        {"x", "mango"}, {"y", "mango"},
      ]
      hubs = Insights.detect_hubs(build_graph(edges), top_n: 3)
      same_degree = hubs.select { |h| h.degree == 2 }.map(&.name)
      same_degree.should eq same_degree.sort
    end
  end

  describe ".detect_bridges" do
    it "returns empty list for empty graph" do
      bridges = Insights.detect_bridges(CodeGraph.new)
      bridges.should eq [] of Bridge
    end

    it "identifies bridge node between two cliques" do
      edges = [
        {"a", "b"}, {"b", "c"}, {"a", "c"},
        {"d", "e"}, {"e", "f"}, {"d", "f"},
        {"c", "bridge"}, {"bridge", "d"},
      ]
      bridges = Insights.detect_bridges(build_graph(edges))
      names = bridges.map(&.name)
      names.should contain "bridge"
    end

    it "returns at most 3 entries" do
      edges = (0...20).map { |i| {"n#{i}", "n#{i + 1}"} }
      bridges = Insights.detect_bridges(build_graph(edges))
      bridges.size.should be <= 3
    end

    it "excludes nodes with zero betweenness" do
      edges = [
        {"a", "b"},
        {"c", "d"},
      ]
      bridges = Insights.detect_bridges(build_graph(edges))
      bridges.each { |b| b.score.should be > 0.0 }
    end
  end

  describe ".detect_surprises" do
    it "returns empty list for empty graph" do
      r = Insights.detect_surprises(CodeGraph.new)
      r.should eq [] of SurprisingConnection
    end

    it "flags cross-community edges" do
      edges = [
        {"a", "b"}, {"b", "c"}, {"a", "c"},
        {"d", "e"}, {"e", "f"}, {"d", "f"},
        {"a", "d"},
      ]
      graph = build_graph(edges)
      communities = CommunityDetection.detect(graph)
      surprises = Insights.detect_surprises(graph, communities: communities)

      endpoints = surprises.map { |s| [s.source, s.target].sort.join("|") }
      endpoints.should contain(["a", "d"].sort.join("|"))

      xcom = surprises.find { |s| [s.source, s.target].sort.join("|") == ["a", "d"].sort.join("|") }
      xcom.should_not be_nil
      xcom.not_nil!.reasons.should contain "cross-community"
    end

    it "peripheral-to-hub edges earn a +1 bonus" do
      edges = [
        {"hub", "a"}, {"hub", "b"}, {"hub", "c"}, {"hub", "d"}, {"hub", "e"},
        {"leaf", "hub"},
      ]
      surprises = Insights.detect_surprises(build_graph(edges))
      leaf_hub = surprises.find { |s| [s.source, s.target].sort.join("|") == ["hub", "leaf"].sort.join("|") }
      leaf_hub.should_not be_nil
      leaf_hub.not_nil!.reasons.should contain "peripheral-to-hub"
    end

    it "respects topN option" do
      edges = [] of Tuple(String, String)
      10.times do |i|
        edges << {"a#{i}", "a#{i + 1}"}
        edges << {"b#{i}", "b#{i + 1}"}
      end
      10.times { |i| edges << {"a#{i}", "b#{i}"} }
      r = Insights.detect_surprises(build_graph(edges), top_n: 3)
      r.size.should be <= 3
    end

    it "scores descending with deterministic tiebreak" do
      edges = [
        {"a", "b"}, {"b", "c"}, {"a", "c"},
        {"d", "e"}, {"e", "f"}, {"d", "f"},
        {"a", "d"}, {"c", "f"},
      ]
      r1 = Insights.detect_surprises(build_graph(edges))
      r2 = Insights.detect_surprises(build_graph(edges))
      r1.should eq r2
      (1...r1.size).each do |i|
        r1[i - 1].score.should be >= r1[i].score
      end
    end
  end
end
