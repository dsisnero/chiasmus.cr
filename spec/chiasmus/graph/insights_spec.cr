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
end
