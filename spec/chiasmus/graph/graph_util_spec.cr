require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/graph_util"

include Chiasmus::Graph

describe GraphUtil do
  describe ".collect_nodes" do
    it "collects all nodes from defines and calls" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "foo", kind: SymbolKind::Function, line: 1),
          DefinesFact.new(file: "a.ts", name: "bar", kind: SymbolKind::Function, line: 3),
        ],
        calls: [
          CallsFact.new(caller: "foo", callee: "bar"),
          CallsFact.new(caller: "bar", callee: "baz"),
        ],
      )
      nodes = GraphUtil.collect_nodes(graph)
      nodes.should contain "foo"
      nodes.should contain "bar"
      nodes.should contain "baz"
    end
  end

  describe ".build_undirected_graph" do
    it "builds symmetric adjacency list" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "a", kind: SymbolKind::Function, line: 1),
          DefinesFact.new(file: "a.ts", name: "b", kind: SymbolKind::Function, line: 2),
        ],
        calls: [
          CallsFact.new(caller: "a", callee: "b"),
        ],
      )
      ug = GraphUtil.build_undirected_graph(graph)
      ug["a"].should contain "b"
      ug["b"].should contain "a"
    end

    it "drops self-loops" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "a", kind: SymbolKind::Function, line: 1),
        ],
        calls: [
          CallsFact.new(caller: "a", callee: "a"),
        ],
      )
      ug = GraphUtil.build_undirected_graph(graph)
      ug["a"].should be_empty
    end

    it "deduplicates edges" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "a", kind: SymbolKind::Function, line: 1),
          DefinesFact.new(file: "a.ts", name: "b", kind: SymbolKind::Function, line: 2),
        ],
        calls: [
          CallsFact.new(caller: "a", callee: "b"),
          CallsFact.new(caller: "a", callee: "b"),
        ],
      )
      ug = GraphUtil.build_undirected_graph(graph)
      ug["a"].size.should eq 1
    end
  end

  describe ".for_each_undirected_edge" do
    it "visits each undirected edge once" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "a", kind: SymbolKind::Function, line: 1),
          DefinesFact.new(file: "a.ts", name: "b", kind: SymbolKind::Function, line: 2),
          DefinesFact.new(file: "a.ts", name: "c", kind: SymbolKind::Function, line: 3),
        ],
        calls: [
          CallsFact.new(caller: "a", callee: "b"),
          CallsFact.new(caller: "b", callee: "a"),
          CallsFact.new(caller: "a", callee: "c"),
        ],
      )
      edges = [] of Tuple(String, String)
      GraphUtil.for_each_undirected_edge(graph) { |a, b| edges << {a, b} }
      edges.size.should eq 2
    end
  end

  describe ".undirected_degree" do
    it "counts distinct neighbors per node" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "hub", kind: SymbolKind::Function, line: 1),
          DefinesFact.new(file: "a.ts", name: "a", kind: SymbolKind::Function, line: 2),
          DefinesFact.new(file: "a.ts", name: "b", kind: SymbolKind::Function, line: 3),
        ],
        calls: [
          CallsFact.new(caller: "hub", callee: "a"),
          CallsFact.new(caller: "hub", callee: "b"),
        ],
      )
      degree = GraphUtil.undirected_degree(graph)
      degree["hub"].should eq 2
      degree["a"].should eq 1
      degree["b"].should eq 1
    end
  end
end
