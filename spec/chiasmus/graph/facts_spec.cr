require "spec"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/facts"
require "../../../src/chiasmus/graph/extractor"
require "../../../src/chiasmus/solvers/prolog_solver"

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

    program.should contain("defines('test.ts', main, function, 1, 0).")
    program.should contain("calls(main, helper).")
    program.should contain("exports('test.ts', main).")
    program.should contain("entry_point(main).")
    program.should contain("reaches(A, B)")
    program.should contain("dead(Name)")
  end

  describe "solver integration" do
    it "generates syntactically valid Prolog accepted by solver" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new(path: "test.ts", content: "\n        function a() { b(); }\n        function b() { c(); }\n        function c() {}\n        export function a() {}\n      "),
      ])

      program = Chiasmus::Graph::Facts.graph_to_prolog(graph)
      solver = Chiasmus::Solvers::PrologSolver.new
      result = solver.solve(
        Chiasmus::Solvers::PrologSolverInput.new(program: program, query: "defines(_, Name, function, _, _).")
      )
      solver.dispose

      result.status.should eq("success")
      if result.is_a?(Chiasmus::Solvers::SuccessResult)
        names = result.answers.map { |a| a.bindings["Name"] }
        names.should contain("a")
        names.should contain("b")
        names.should contain("c")
      end
    end

    it "produces queryable call facts" do
      graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(file: "test.ts", name: "a", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
          Chiasmus::Graph::DefinesFact.new(file: "test.ts", name: "b", kind: Chiasmus::Graph::SymbolKind::Function, line: 2),
        ],
        calls: [Chiasmus::Graph::CallsFact.new(caller: "a", callee: "b")],
        imports: [] of Chiasmus::Graph::ImportsFact,
        exports: [] of Chiasmus::Graph::ExportsFact,
        contains: [] of Chiasmus::Graph::ContainsFact
      )

      program = Chiasmus::Graph::Facts.graph_to_prolog(graph)
      solver = Chiasmus::Solvers::PrologSolver.new
      result = solver.solve(
        Chiasmus::Solvers::PrologSolverInput.new(program: program, query: "calls(a, X).")
      )
      solver.dispose

      result.status.should eq("success")
      if result.is_a?(Chiasmus::Solvers::SuccessResult)
        result.answers[0].bindings["X"].should eq("b")
      end
    end

    it "handles file paths with slashes in atoms" do
      graph = Chiasmus::Graph::CodeGraph.new(
        defines: [Chiasmus::Graph::DefinesFact.new(file: "src/server.ts", name: "main", kind: Chiasmus::Graph::SymbolKind::Function, line: 1)],
        calls: [] of Chiasmus::Graph::CallsFact,
        imports: [] of Chiasmus::Graph::ImportsFact,
        exports: [] of Chiasmus::Graph::ExportsFact,
        contains: [] of Chiasmus::Graph::ContainsFact
      )

      program = Chiasmus::Graph::Facts.graph_to_prolog(graph)
      solver = Chiasmus::Solvers::PrologSolver.new
      result = solver.solve(
        Chiasmus::Solvers::PrologSolverInput.new(program: program, query: "defines(File, main, function, _, _).")
      )
      solver.dispose

      result.status.should eq("success")
      if result.is_a?(Chiasmus::Solvers::SuccessResult)
        result.answers[0].bindings["File"].should contain("server")
      end
    end

    it "auto-detects entry points from exports" do
      graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(file: "test.ts", name: "main", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
          Chiasmus::Graph::DefinesFact.new(file: "test.ts", name: "helper", kind: Chiasmus::Graph::SymbolKind::Function, line: 5),
        ],
        calls: [] of Chiasmus::Graph::CallsFact,
        imports: [] of Chiasmus::Graph::ImportsFact,
        exports: [Chiasmus::Graph::ExportsFact.new(file: "test.ts", name: "main")],
        contains: [] of Chiasmus::Graph::ContainsFact
      )

      program = Chiasmus::Graph::Facts.graph_to_prolog(graph)
      solver = Chiasmus::Solvers::PrologSolver.new
      result = solver.solve(
        Chiasmus::Solvers::PrologSolverInput.new(program: program, query: "entry_point(X).")
      )
      solver.dispose

      result.status.should eq("success")
      if result.is_a?(Chiasmus::Solvers::SuccessResult)
        result.answers.size.should eq(1)
        result.answers[0].bindings["X"].should eq("main")
      end
    end

    it "cycle-safe reachability works for transitive calls" do
      graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(file: "t.ts", name: "a", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
          Chiasmus::Graph::DefinesFact.new(file: "t.ts", name: "b", kind: Chiasmus::Graph::SymbolKind::Function, line: 2),
          Chiasmus::Graph::DefinesFact.new(file: "t.ts", name: "c", kind: Chiasmus::Graph::SymbolKind::Function, line: 3),
        ],
        calls: [
          Chiasmus::Graph::CallsFact.new(caller: "a", callee: "b"),
          Chiasmus::Graph::CallsFact.new(caller: "b", callee: "c"),
        ],
        imports: [] of Chiasmus::Graph::ImportsFact,
        exports: [] of Chiasmus::Graph::ExportsFact,
        contains: [] of Chiasmus::Graph::ContainsFact
      )

      program = Chiasmus::Graph::Facts.graph_to_prolog(graph)
      solver = Chiasmus::Solvers::PrologSolver.new
      result = solver.solve(
        Chiasmus::Solvers::PrologSolverInput.new(program: program, query: "reaches(a, c).")
      )
      solver.dispose

      result.status.should eq("success")
      if result.is_a?(Chiasmus::Solvers::SuccessResult)
        result.answers.size.should be > 0
      end
    end

    it "dead code detection finds unreachable functions" do
      graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(file: "t.ts", name: "main", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
          Chiasmus::Graph::DefinesFact.new(file: "t.ts", name: "used", kind: Chiasmus::Graph::SymbolKind::Function, line: 5),
          Chiasmus::Graph::DefinesFact.new(file: "t.ts", name: "unused", kind: Chiasmus::Graph::SymbolKind::Function, line: 10),
        ],
        calls: [Chiasmus::Graph::CallsFact.new(caller: "main", callee: "used")],
        imports: [] of Chiasmus::Graph::ImportsFact,
        exports: [Chiasmus::Graph::ExportsFact.new(file: "t.ts", name: "main")],
        contains: [] of Chiasmus::Graph::ContainsFact
      )

      program = Chiasmus::Graph::Facts.graph_to_prolog(graph)
      solver = Chiasmus::Solvers::PrologSolver.new
      result = solver.solve(
        Chiasmus::Solvers::PrologSolverInput.new(program: program, query: "dead(X).")
      )
      solver.dispose

      result.status.should eq("success")
      if result.is_a?(Chiasmus::Solvers::SuccessResult)
        dead_names = result.answers.map { |a| a.bindings["X"] }
        dead_names.should contain("unused")
        dead_names.should_not contain("main")
        dead_names.should_not contain("used")
      end
    end
  end

  describe "DefinesFact end_line" do
    it "defaults end_line to 0 for backward compatibility" do
      fact = Chiasmus::Graph::DefinesFact.new(
        file: "test.cr",
        name: "foo",
        kind: Chiasmus::Graph::SymbolKind::Function,
        line: 10
      )
      fact.end_line.should eq(0)
    end

    it "accepts explicit end_line" do
      fact = Chiasmus::Graph::DefinesFact.new(
        file: "test.cr",
        name: "bar",
        kind: Chiasmus::Graph::SymbolKind::Method,
        line: 20,
        end_line: 45
      )
      fact.end_line.should eq(45)
    end

    it "emits defines/5 with end_line in Prolog facts" do
      graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(
            file: "test.cr", name: "has_range", kind: Chiasmus::Graph::SymbolKind::Function,
            line: 10, end_line: 25
          ),
          Chiasmus::Graph::DefinesFact.new(
            file: "test.cr", name: "no_range", kind: Chiasmus::Graph::SymbolKind::Function,
            line: 30
          ),
        ]
      )
      program = Chiasmus::Graph::Facts.graph_to_prolog(graph)
      program.should contain("defines('test.cr', has_range, function, 10, 25).")
      program.should contain("defines('test.cr', no_range, function, 30, 0).")
      program.should contain(":- dynamic(defines/5).")
    end

    it "captures end_line > 0 from tree-sitter walkers" do
      tmp = File.tempfile("walker_endline", ".cr") do |file|
        file.print <<-CRYSTAL
          module TestMod
            def self.hello(name : String) : String
              "Hello, \#{name}"
            end
          end
          CRYSTAL
      end
      path = tmp.path
      begin
        files = [Chiasmus::Graph::SourceFile.new(path: path, content: File.read(path))]
        graph = Chiasmus::Graph::Extractor.extract_graph(files, cache_dir: nil)
        hello_def = graph.defines.find { |d| d.name == "hello" }
        hello_def.should_not be_nil
        if hello_def
          hello_def.line.should eq(2)
          hello_def.end_line.should be > hello_def.line
        end
      ensure
        tmp.delete
      end
    end
  end
end
