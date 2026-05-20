require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/diff"

include Chiasmus::Graph

describe GraphDiffer do
  describe ".diff" do
    it "detects added and removed nodes" do
      before = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "oldFn", kind: SymbolKind::Function, line: 1),
        ],
      )
      after = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "newFn", kind: SymbolKind::Function, line: 1),
        ],
      )

      result = GraphDiffer.diff(before, after)
      result.added_nodes.should eq ["newFn"]
      result.removed_nodes.should eq ["oldFn"]
    end

    it "detects added and removed edges" do
      before = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "a", kind: SymbolKind::Function, line: 1),
          DefinesFact.new(file: "a.ts", name: "b", kind: SymbolKind::Function, line: 2),
        ],
        calls: [
          CallsFact.new(caller: "a", callee: "b"),
        ],
      )
      after = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "a", kind: SymbolKind::Function, line: 1),
          DefinesFact.new(file: "a.ts", name: "c", kind: SymbolKind::Function, line: 3),
        ],
        calls: [
          CallsFact.new(caller: "a", callee: "c"),
        ],
      )

      result = GraphDiffer.diff(before, after)
      result.removed_edges.size.should eq 1
      result.removed_edges[0].source.should eq "a"
      result.removed_edges[0].target.should eq "b"
      result.added_edges.size.should eq 1
      result.added_edges[0].source.should eq "a"
      result.added_edges[0].target.should eq "c"
    end

    it "returns 'no changes' for identical graphs" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "fn", kind: SymbolKind::Function, line: 1),
        ],
        calls: [
          CallsFact.new(caller: "fn", callee: "fn"),
        ],
      )

      result = GraphDiffer.diff(graph, graph)
      result.summary.should eq "no changes"
      result.added_nodes.should be_empty
      result.removed_nodes.should be_empty
    end

    it "detects import diffs" do
      before = CodeGraph.new(
        imports: [
          ImportsFact.new(file: "a.ts", name: "oldDep", source: "./old"),
        ],
      )
      after = CodeGraph.new(
        imports: [
          ImportsFact.new(file: "a.ts", name: "newDep", source: "./new"),
        ],
      )

      result = GraphDiffer.diff(before, after)
      result.added_imports.size.should eq 1
      result.removed_imports.size.should eq 1
    end

    it "generates human-readable summary" do
      before = CodeGraph.new
      after = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "added", kind: SymbolKind::Function, line: 1),
        ],
      )

      result = GraphDiffer.diff(before, after)
      result.summary.should contain "1 new node"
    end
  end
end
