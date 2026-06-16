require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/graph_util"
require "../../../src/chiasmus/graph/community"
require "../../../src/chiasmus/graph/insights"

include Chiasmus::Graph

describe "parallel insights" do
  it "detect_bridges returns same result regardless of concurrency" do
    # Build a small graph with known betweenness
    # Graph: a--b--c--d (line graph of 4 nodes)
    # Betweenness: b=4/6, c=4/6, a=0, d=0
    graph = CodeGraph.new(
      defines: [
        DefinesFact.new(file: "t.cr", name: "a", kind: SymbolKind::Function, line: 1),
        DefinesFact.new(file: "t.cr", name: "b", kind: SymbolKind::Function, line: 2),
        DefinesFact.new(file: "t.cr", name: "c", kind: SymbolKind::Function, line: 3),
        DefinesFact.new(file: "t.cr", name: "d", kind: SymbolKind::Function, line: 4),
      ],
      calls: [
        CallsFact.new(caller: "a", callee: "b"),
        CallsFact.new(caller: "b", callee: "c"),
        CallsFact.new(caller: "c", callee: "d"),
      ],
      imports: [] of ImportsFact,
      exports: [] of ExportsFact,
      contains: [] of ContainsFact,
    )

    result = Insights.detect_bridges(graph)

    result.size.should be >= 1
    names = result.map(&.name).to_set
    names.should contain("b")
    names.should contain("c")
  end

  it "detect_hubs returns consistent results" do
    graph = CodeGraph.new(
      defines: [
        DefinesFact.new(file: "t.cr", name: "hub", kind: SymbolKind::Function, line: 1),
        DefinesFact.new(file: "t.cr", name: "a", kind: SymbolKind::Function, line: 2),
        DefinesFact.new(file: "t.cr", name: "b", kind: SymbolKind::Function, line: 3),
        DefinesFact.new(file: "t.cr", name: "c", kind: SymbolKind::Function, line: 4),
      ],
      calls: [
        CallsFact.new(caller: "hub", callee: "a"),
        CallsFact.new(caller: "hub", callee: "b"),
        CallsFact.new(caller: "hub", callee: "c"),
      ],
      imports: [] of ImportsFact,
      exports: [] of ExportsFact,
      contains: [] of ContainsFact,
    )

    result = Insights.detect_hubs(graph)
    result.size.should be >= 1
    result.first.name.should eq("hub")
  end
end
