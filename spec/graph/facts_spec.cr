require "../spec_helper"

describe Chiasmus::Graph::Facts do
  describe ".escape_atom" do
    it "leaves simple lowercase atoms unquoted" do
      Chiasmus::Graph::Facts.escape_atom("main").should eq("main")
      Chiasmus::Graph::Facts.escape_atom("helper_func").should eq("helper_func")
    end

    it "quotes atoms with uppercase letters" do
      Chiasmus::Graph::Facts.escape_atom("Main").should eq("'Main'")
      Chiasmus::Graph::Facts.escape_atom("CamelCase").should eq("'CamelCase'")
    end

    it "quotes atoms with special characters" do
      result = Chiasmus::Graph::Facts.escape_atom("helper-x")
      result.should start_with("'")
      result.should end_with("'")
    end

    it "escapes internal single quotes" do
      result = Chiasmus::Graph::Facts.escape_atom("it's")
      result.should eq("'it''s'")
    end

    it "handles file paths with slashes" do
      result = Chiasmus::Graph::Facts.escape_atom("src/main.go")
      result.should start_with("'")
      result.should contain("/")
    end
  end

  describe ".graph_to_prolog" do
    it "generates syntactically valid Prolog facts" do
      graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(file: "main.go", name: "main", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
        ],
        calls: [
          Chiasmus::Graph::CallsFact.new(caller: "main", callee: "helper"),
        ],
        imports: [] of Chiasmus::Graph::ImportsFact,
        exports: [] of Chiasmus::Graph::ExportsFact,
        contains: [] of Chiasmus::Graph::ContainsFact,
      )

      facts = Chiasmus::Graph::Facts.graph_to_prolog(graph)
      facts.should contain("defines(")
      facts.should contain("calls(")
      facts.should contain("main")
      facts.should contain("helper")
    end

    it "auto-detects entry points from exports" do
      graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(file: "app.go", name: "Server", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
        ],
        calls: [] of Chiasmus::Graph::CallsFact,
        imports: [] of Chiasmus::Graph::ImportsFact,
        exports: [
          Chiasmus::Graph::ExportsFact.new(file: "app.go", name: "Server"),
        ],
        contains: [] of Chiasmus::Graph::ContainsFact,
      )

      facts = Chiasmus::Graph::Facts.graph_to_prolog(graph)
      facts.should contain("entry_point(")
      facts.should contain("Server")
    end

    it "overrides entry points when provided explicitly" do
      graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(file: "app.go", name: "custom", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
        ],
        calls: [] of Chiasmus::Graph::CallsFact,
        imports: [] of Chiasmus::Graph::ImportsFact,
        exports: [
          Chiasmus::Graph::ExportsFact.new(file: "app.go", name: "other"),
        ],
        contains: [] of Chiasmus::Graph::ContainsFact,
      )

      facts = Chiasmus::Graph::Facts.graph_to_prolog(graph, ["custom"])
      facts.should contain("entry_point(custom)")
      facts.should_not contain("entry_point(other)")
    end

    it "includes BUILTIN_RULES with member, reaches, path, dead predicates" do
      graph = Chiasmus::Graph::CodeGraph.new(
        defines: [] of Chiasmus::Graph::DefinesFact,
        calls: [] of Chiasmus::Graph::CallsFact,
        imports: [] of Chiasmus::Graph::ImportsFact,
        exports: [] of Chiasmus::Graph::ExportsFact,
        contains: [] of Chiasmus::Graph::ContainsFact,
      )

      facts = Chiasmus::Graph::Facts.graph_to_prolog(graph)
      facts.should contain("member(")
      facts.should contain("reaches(")
      facts.should contain("dead(")
    end
  end
end
