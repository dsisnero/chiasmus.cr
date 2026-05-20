require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/entry_points"

include Chiasmus::Graph

describe EntryPoints do
  describe ".detect" do
    it "returns zero-in-degree exports" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "main", kind: SymbolKind::Function, line: 1),
          DefinesFact.new(file: "a.ts", name: "helper", kind: SymbolKind::Function, line: 5),
        ],
        calls: [
          CallsFact.new(caller: "main", callee: "helper"),
        ],
        exports: [
          ExportsFact.new(file: "a.ts", name: "main"),
          ExportsFact.new(file: "a.ts", name: "helper"),
        ],
      )
      result = EntryPoints.detect(graph)
      result.should eq ["main"]
    end

    it "falls back to all exports when every export has a caller" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "main", kind: SymbolKind::Function, line: 1),
          DefinesFact.new(file: "a.ts", name: "helper", kind: SymbolKind::Function, line: 5),
        ],
        calls: [
          CallsFact.new(caller: "main", callee: "helper"),
          CallsFact.new(caller: "helper", callee: "main"),
        ],
        exports: [
          ExportsFact.new(file: "a.ts", name: "main"),
          ExportsFact.new(file: "a.ts", name: "helper"),
        ],
      )
      result = EntryPoints.detect(graph)
      result.sort.should eq ["helper", "main"]
    end

    it "falls back to zero-in-degree functions when no exports" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "main", kind: SymbolKind::Function, line: 1),
          DefinesFact.new(file: "a.ts", name: "helper", kind: SymbolKind::Function, line: 5),
          DefinesFact.new(file: "a.ts", name: "unused", kind: SymbolKind::Function, line: 10),
        ],
        calls: [
          CallsFact.new(caller: "main", callee: "helper"),
        ],
      )
      result = EntryPoints.detect(graph)
      result.should eq ["main", "unused"]
    end

    it "excludes methods from entry points" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "run", kind: SymbolKind::Method, line: 2),
          DefinesFact.new(file: "a.ts", name: "main", kind: SymbolKind::Function, line: 5),
        ],
        calls: [] of CallsFact,
        exports: [
          ExportsFact.new(file: "a.ts", name: "run"),
          ExportsFact.new(file: "a.ts", name: "main"),
        ],
      )
      result = EntryPoints.detect(graph)
      result.should eq ["main"]
      result.should_not contain "run"
    end
  end
end
