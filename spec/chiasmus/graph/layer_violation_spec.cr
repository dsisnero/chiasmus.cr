require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/layer_violation"

include Chiasmus::Graph

private def make_graph(defines : Array(NamedTuple(file: String, name: String, kind: String)), calls : Array(Tuple(String, String))) : CodeGraph
  CodeGraph.new(
    defines: defines.map { |d|
      DefinesFact.new(
        file: d[:file],
        name: d[:name],
        kind: case d[:kind]
        when "class"  then SymbolKind::Class
        when "method" then SymbolKind::Method
        else               SymbolKind::Function
        end,
        line: 1,
      )
    },
    calls: calls.map { |(caller, callee)| CallsFact.new(caller: caller, callee: callee) },
  )
end

describe LayerViolation do
  describe ".find" do
    it "detects a call that skips a layer" do
      graph = make_graph(
        [
          {file: "src/handlers/user.ts", name: "handleCreateUser", kind: "function"},
          {file: "src/services/user.ts", name: "createUser", kind: "function"},
          {file: "src/db/client.ts", name: "query", kind: "function"},
        ],
        [{"handleCreateUser", "query"}],
      )
      violations = LayerViolation.find(graph)
      violations.size.should be > 0
      violations[0].caller.should eq "handleCreateUser"
      violations[0].callee.should eq "query"
    end

    it "allows calls within the same layer" do
      graph = make_graph(
        [
          {file: "src/handlers/user.ts", name: "listUsers", kind: "function"},
          {file: "src/handlers/auth.ts", name: "checkAuth", kind: "function"},
        ],
        [{"listUsers", "checkAuth"}],
      )
      violations = LayerViolation.find(graph)
      violations.size.should eq 0
    end

    it "allows calls to adjacent layer" do
      graph = make_graph(
        [
          {file: "src/handlers/user.ts", name: "handleGetUser", kind: "function"},
          {file: "src/services/user.ts", name: "getUser", kind: "function"},
        ],
        [{"handleGetUser", "getUser"}],
      )
      violations = LayerViolation.find(graph)
      violations.size.should eq 0
    end

    it "detects multiple violations" do
      graph = make_graph(
        [
          {file: "src/handlers/user.ts", name: "h1", kind: "function"},
          {file: "src/handlers/admin.ts", name: "h2", kind: "function"},
          {file: "src/repositories/user.ts", name: "r1", kind: "function"},
        ],
        [{"h1", "r1"}, {"h2", "r1"}],
      )
      violations = LayerViolation.find(graph)
      violations.size.should eq 2
    end

    it "returns empty when no calls exist" do
      graph = make_graph(
        [{file: "src/handlers/user.ts", name: "h1", kind: "function"}],
        [] of Tuple(String, String),
      )
      violations = LayerViolation.find(graph)
      violations.size.should eq 0
    end
  end
end
