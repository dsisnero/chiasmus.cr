require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/graph_util"
require "../../../src/chiasmus/graph/insights"

include Chiasmus::Graph

describe Insights do
  describe ".detect_hubs" do
    it "returns top-degree nodes" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "hub", kind: SymbolKind::Function, line: 1),
          DefinesFact.new(file: "a.ts", name: "a", kind: SymbolKind::Function, line: 2),
          DefinesFact.new(file: "a.ts", name: "b", kind: SymbolKind::Function, line: 3),
          DefinesFact.new(file: "a.ts", name: "c", kind: SymbolKind::Function, line: 4),
        ],
        calls: [
          CallsFact.new(caller: "hub", callee: "a"),
          CallsFact.new(caller: "hub", callee: "b"),
          CallsFact.new(caller: "hub", callee: "c"),
          CallsFact.new(caller: "a", callee: "b"),
        ],
      )
      hubs = Insights.detect_hubs(graph, 3)
      hubs.size.should eq 3
      hubs[0].name.should eq "hub"
      hubs[0].degree.should eq 3
    end

    it "returns empty array for empty graph" do
      graph = CodeGraph.new
      hubs = Insights.detect_hubs(graph)
      hubs.should be_empty
    end

    it "caps at top_n" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "a", kind: SymbolKind::Function, line: 1),
          DefinesFact.new(file: "a.ts", name: "b", kind: SymbolKind::Function, line: 2),
          DefinesFact.new(file: "a.ts", name: "c", kind: SymbolKind::Function, line: 3),
          DefinesFact.new(file: "a.ts", name: "d", kind: SymbolKind::Function, line: 4),
        ],
        calls: [
          CallsFact.new(caller: "a", callee: "b"),
          CallsFact.new(caller: "b", callee: "c"),
          CallsFact.new(caller: "c", callee: "d"),
        ],
      )
      hubs = Insights.detect_hubs(graph, 2)
      hubs.size.should eq 2
    end
  end
end
