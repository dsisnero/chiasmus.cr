require "spec"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/facts"

describe Chiasmus::Graph::Facts do
  it "leaves simple atoms unquoted" do
    Chiasmus::Graph::Facts.escape_atom("hello").should eq("hello")
    Chiasmus::Graph::Facts.escape_atom("foo_bar").should eq("foo_bar")
  end

  it "quotes atoms with special characters" do
    Chiasmus::Graph::Facts.escape_atom("src/server.ts").should eq("'src/server.ts'")
    Chiasmus::Graph::Facts.escape_atom("my-func").should eq("'my-func'")
    Chiasmus::Graph::Facts.escape_atom("MyClass").should eq("'MyClass'")
  end

  it "escapes internal single quotes" do
    Chiasmus::Graph::Facts.escape_atom("it's").should eq("'it''s'")
  end

  it "builds a Prolog program with facts, entry points, and builtin rules" do
    graph = Chiasmus::Graph::CodeGraph.new(
      defines: [
        Chiasmus::Graph::DefinesFact.new(
          file: "test.ts",
          name: "main",
          kind: Chiasmus::Graph::SymbolKind::Function,
          line: 1
        ),
        Chiasmus::Graph::DefinesFact.new(
          file: "test.ts",
          name: "helper",
          kind: Chiasmus::Graph::SymbolKind::Function,
          line: 5
        ),
      ],
      calls: [
        Chiasmus::Graph::CallsFact.new(caller: "main", callee: "helper"),
      ],
      exports: [
        Chiasmus::Graph::ExportsFact.new(file: "test.ts", name: "main"),
      ]
    )

    program = Chiasmus::Graph::Facts.graph_to_prolog(graph)

    program.should contain("defines('test.ts', main, function, 1).")
    program.should contain("calls(main, helper).")
    program.should contain("exports('test.ts', main).")
    program.should contain("entry_point(main).")
    program.should contain("reaches(A, B)")
    program.should contain("dead(Name)")
  end
end
