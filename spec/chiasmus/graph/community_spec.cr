require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/graph_util"
require "../../../src/chiasmus/graph/community"

include Chiasmus::Graph

describe CommunityDetection do
  describe ".detect" do
    it "returns empty for empty graph" do
      graph = CodeGraph.new
      result = CommunityDetection.detect(graph)
      result.should be_empty
    end

    it "assigns each disconnected node to its own community" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "a", kind: SymbolKind::Function, line: 1),
          DefinesFact.new(file: "a.ts", name: "b", kind: SymbolKind::Function, line: 2),
        ],
      )
      result = CommunityDetection.detect(graph)
      result.size.should eq 2
      result.map(&.members).flatten.sort.should eq ["a", "b"]
    end

    it "groups connected nodes into same community" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "a", kind: SymbolKind::Function, line: 1),
          DefinesFact.new(file: "a.ts", name: "b", kind: SymbolKind::Function, line: 2),
        ],
        calls: [
          CallsFact.new(caller: "a", callee: "b"),
          CallsFact.new(caller: "b", callee: "a"),
        ],
      )
      result = CommunityDetection.detect(graph)
      result.size.should eq 1
      result[0].members.sort.should eq ["a", "b"]
    end

    it "returns Community objects with id, members, cohesion" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "a", kind: SymbolKind::Function, line: 1),
          DefinesFact.new(file: "a.ts", name: "b", kind: SymbolKind::Function, line: 2),
        ],
        calls: [
          CallsFact.new(caller: "a", callee: "b"),
          CallsFact.new(caller: "b", callee: "a"),
        ],
      )
      result = CommunityDetection.detect(graph)
      result.first.id.should be >= 0
      result.first.members.should be_a Array(String)
      result.first.cohesion.should be >= 0.0
    end

    it "is deterministic with same seed" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "a", kind: SymbolKind::Function, line: 1),
          DefinesFact.new(file: "a.ts", name: "b", kind: SymbolKind::Function, line: 2),
          DefinesFact.new(file: "a.ts", name: "c", kind: SymbolKind::Function, line: 3),
        ],
        calls: [
          CallsFact.new(caller: "a", callee: "b"),
          CallsFact.new(caller: "b", callee: "c"),
        ],
      )
      r1 = CommunityDetection.detect(graph, seed: 42)
      r2 = CommunityDetection.detect(graph, seed: 42)
      r1.map(&.members).should eq r2.map(&.members)
    end
  end
end
