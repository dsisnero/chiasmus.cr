require "../spec_helper"

describe "Dogfood integration: realistic problem domains" do
  describe "Z3 solver" do
    it "detects that 3 tasks cannot fit in 2 non-overlapping slots" do
      solver = Chiasmus::Solvers::Z3Solver.new

      # 3 distinct tasks (A, B, C), each must be in set {1, 2}
      # Impossible: 3 distinct values can't fit in 2 possible values
      smtlib = <<-SMTLIB
        (declare-const taskA Int)
        (declare-const taskB Int)
        (declare-const taskC Int)
        (assert (or (= taskA 1) (= taskA 2)))
        (assert (or (= taskB 1) (= taskB 2)))
        (assert (or (= taskC 1) (= taskC 2)))
        (assert (and (not (= taskA taskB)) (not (= taskA taskC)) (not (= taskB taskC))))
      SMTLIB

      result = solver.solve(Chiasmus::Solvers::Z3SolverInput.new(
        type: Chiasmus::Solvers::SolverType::Z3,
        smtlib: smtlib
      ))

      result.status.should eq("unsat")
    end

    it "detects contradictory firewall rules" do
      solver = Chiasmus::Solvers::Z3Solver.new

      # Port 80 is both allowed and denied
      smtlib = <<-SMTLIB
        (declare-const allow_port_80 Bool)
        (declare-const deny_port_80 Bool)
        (assert allow_port_80)
        (assert (not allow_port_80))
      SMTLIB

      result = solver.solve(Chiasmus::Solvers::Z3SolverInput.new(
        type: Chiasmus::Solvers::SolverType::Z3,
        smtlib: smtlib
      ))

      result.status.should eq("unsat")
    end
  end

  describe "Graph + Prolog" do
    it "produces queryable Prolog facts from Go source" do
      graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(file: "app.go", name: "main", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
          Chiasmus::Graph::DefinesFact.new(file: "app.go", name: "helper", kind: Chiasmus::Graph::SymbolKind::Function, line: 3),
        ],
        calls: [
          Chiasmus::Graph::CallsFact.new(caller: "main", callee: "helper"),
        ],
        imports: [] of Chiasmus::Graph::ImportsFact,
        exports: [
          Chiasmus::Graph::ExportsFact.new(file: "app.go", name: "main"),
        ],
        contains: [] of Chiasmus::Graph::ContainsFact,
      )

      facts = Chiasmus::Graph::Facts.graph_to_prolog(graph, ["main"])
      facts.should contain("defines(")
      facts.should contain("calls(")
      facts.should contain("entry_point(main)")
      facts.should contain("reaches(")
    end
  end
end
