require "../spec_helper"

private def prolog_available?
  Chiasmus::Solvers::Session.instance
  true
rescue
  false
end

describe Chiasmus::Solvers::PrologSolver do
  describe "#type" do
    it "returns Prolog solver type" do
      solver = Chiasmus::Solvers::PrologSolver.new
      solver.type.should eq(Chiasmus::Solvers::SolverType::Prolog)
    end
  end

  describe "#solve" do
    it "resolves simple fact queries" do
      pending "SWI-Prolog not available" unless prolog_available?
      solver = Chiasmus::Solvers::PrologSolver.new
      input = Chiasmus::Solvers::PrologSolverInput.new(
        type: Chiasmus::Solvers::SolverType::Prolog,
        program: "parent(tom, bob).\nparent(bob, ann).",
        query: "parent(tom, X)",
        explain: false
      )

      result = solver.solve(input)
      result.status.should eq("success")
      result.should be_a(Chiasmus::Solvers::SuccessResult)
    end

    it "returns trace for rule chain when explain=true" do
      pending "SWI-Prolog not available" unless prolog_available?
      solver = Chiasmus::Solvers::PrologSolver.new
      input = Chiasmus::Solvers::PrologSolverInput.new(
        type: Chiasmus::Solvers::SolverType::Prolog,
        program: "parent(tom, bob).\ngrandparent(X, Y) :- parent(X, Z), parent(Z, Y).",
        query: "grandparent(tom, ann)",
        explain: true
      )

      result = solver.solve(input)
      result.status.should eq("success")
    end

    it "rejects non-prolog input type" do
      solver = Chiasmus::Solvers::PrologSolver.new
      result = solver.solve(Chiasmus::Solvers::Z3SolverInput.new(
        type: Chiasmus::Solvers::SolverType::Z3,
        smtlib: "(assert true)"
      ))

      result.status.should eq("error")
    end
  end

  describe "#dispose" do
    it "is a no-op" do
      solver = Chiasmus::Solvers::PrologSolver.new
      solver.dispose # Should not raise
    end
  end
end
