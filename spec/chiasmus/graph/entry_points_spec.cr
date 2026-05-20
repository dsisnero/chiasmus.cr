require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/entry_points"

include Chiasmus::Graph

private def build_graph(
  defines : Array(NamedTuple(name: String, file: String?, kind: String?)),
  calls : Array(Tuple(String, String)),
  export_names : Array(String) = [] of String,
) : CodeGraph
  CodeGraph.new(
    defines: defines.map { |d|
      DefinesFact.new(
        file: d[:file]? || "t.ts",
        name: d[:name],
        kind: case d[:kind]?
        when "method" then SymbolKind::Method
        when "class"  then SymbolKind::Class
        else               SymbolKind::Function
        end,
        line: 1,
      )
    },
    calls: calls.map { |(caller, callee)| CallsFact.new(caller: caller, callee: callee) },
    exports: export_names.map { |name| ExportsFact.new(file: "t.ts", name: name) },
  )
end

describe EntryPoints do
  describe ".detect" do
    it "returns [] for empty graph" do
      r = EntryPoints.detect(CodeGraph.new)
      r.should eq [] of String
    end

    it "returns zero-in-degree exports" do
      graph = build_graph(
        [{name: "main", file: nil, kind: nil}, {name: "helper", file: nil, kind: nil}],
        [{"main", "helper"}],
        ["main", "helper"],
      )
      r = EntryPoints.detect(graph)
      r.should eq ["main"]
    end

    it "falls back to all exports when every export has callers" do
      graph = build_graph(
        [{name: "a", file: nil, kind: nil}, {name: "b", file: nil, kind: nil}],
        [{"a", "b"}, {"b", "a"}],
        ["a", "b"],
      )
      r = EntryPoints.detect(graph)
      r.sort.should eq ["a", "b"]
    end

    it "falls back to zero-in-degree functions when there are no exports" do
      graph = build_graph(
        [{name: "start", file: nil, kind: nil}, {name: "worker", file: nil, kind: nil}],
        [{"start", "worker"}],
        [] of String,
      )
      r = EntryPoints.detect(graph)
      r.should eq ["start"]
    end

    it "ignores methods (dynamic dispatch)" do
      graph = build_graph(
        [
          {name: "MyClass", file: nil, kind: "class"},
          {name: "method", file: nil, kind: "method"},
          {name: "helper", file: nil, kind: "function"},
        ],
        [] of Tuple(String, String),
        ["method", "helper"],
      )
      r = EntryPoints.detect(graph)
      r.should eq ["helper"]
    end

    it "is deterministic (sorted output)" do
      graph = build_graph(
        [{name: "zeta", file: nil, kind: nil}, {name: "alpha", file: nil, kind: nil}, {name: "mu", file: nil, kind: nil}],
        [] of Tuple(String, String),
        ["zeta", "alpha", "mu"],
      )
      r = EntryPoints.detect(graph)
      r.should eq ["alpha", "mu", "zeta"]
    end
  end
end
