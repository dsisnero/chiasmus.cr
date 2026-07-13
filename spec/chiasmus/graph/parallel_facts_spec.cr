require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/facts"
require "../../../src/chiasmus/graph/community"
require "../../../src/chiasmus/graph/insights"

include Chiasmus::Graph

describe "parallel insight facts" do
  it "produces deterministic output with include_insights" do
    graph = CodeGraph.new(
      defines: [
        DefinesFact.new(file: "t.cr", name: "a", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1)),
        DefinesFact.new(file: "t.cr", name: "b", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(2)),
        DefinesFact.new(file: "t.cr", name: "c", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(3)),
        DefinesFact.new(file: "t.cr", name: "hub", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(4)),
        DefinesFact.new(file: "t.cr", name: "bridge", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(5)),
      ],
      calls: [
        CallsFact.new(caller: "a", callee: "b"),
        CallsFact.new(caller: "b", callee: "c"),
        CallsFact.new(caller: "hub", callee: "a"),
        CallsFact.new(caller: "hub", callee: "b"),
        CallsFact.new(caller: "hub", callee: "c"),
      ],
      imports: [] of ImportsFact,
      exports: [] of ExportsFact,
      contains: [] of ContainsFact,
    )

    r1 = Facts.graph_to_prolog(graph, include_insights: true)
    r2 = Facts.graph_to_prolog(graph, include_insights: true)

    r1.should eq(r2)
    r1.should contain("community(")
    r1.should contain("hub(")
    r1.should contain("bridge(")
  end
end
