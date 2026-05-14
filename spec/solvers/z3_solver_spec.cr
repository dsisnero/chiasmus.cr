require "../spec_helper"

describe Chiasmus::Solvers::Z3Solver do
  describe "#type" do
    it "returns Z3 solver type" do
      solver = Chiasmus::Solvers::Z3Solver.new
      solver.type.should eq(Chiasmus::Solvers::SolverType::Z3)
    end
  end

  describe "#solve" do
    it "returns sat with model for satisfiable constraints" do
      solver = Chiasmus::Solvers::Z3Solver.new
      input = Chiasmus::Solvers::Z3SolverInput.new(
        type: Chiasmus::Solvers::SolverType::Z3,
        smtlib: "(declare-const x Int)\n(assert (> x 3))\n"
      )

      result = solver.solve(input)
      result.should be_a(Chiasmus::Solvers::SatResult)
      result.status.should eq("sat")
      model = result.as(Chiasmus::Solvers::SatResult).model
      model.keys.should contain("x")
    end

    it "returns unsat for contradictory constraints" do
      solver = Chiasmus::Solvers::Z3Solver.new
      input = Chiasmus::Solvers::Z3SolverInput.new(
        type: Chiasmus::Solvers::SolverType::Z3,
        smtlib: "(declare-const x Int)\n(assert (> x 10))\n(assert (< x 5))\n"
      )

      result = solver.solve(input)
      result.should be_a(Chiasmus::Solvers::UnsatResult)
      result.status.should eq("unsat")
    end

    it "returns unsat core for unsatisfiable assertions" do
      solver = Chiasmus::Solvers::Z3Solver.new
      input = Chiasmus::Solvers::Z3SolverInput.new(
        type: Chiasmus::Solvers::SolverType::Z3,
        smtlib: "(declare-const x Int)\n(assert (! (> x 10) :named c1))\n(assert (! (< x 5) :named c2))\n"
      )

      result = solver.solve(input)
      result.status.should eq("unsat")
      if result.is_a?(Chiasmus::Solvers::UnsatResult)
        result.unsat_core.should_not be_nil
      end
    end

    it "handles boolean satisfiability" do
      solver = Chiasmus::Solvers::Z3Solver.new
      input = Chiasmus::Solvers::Z3SolverInput.new(
        type: Chiasmus::Solvers::SolverType::Z3,
        smtlib: "(declare-const p Bool)\n(assert p)\n"
      )

      result = solver.solve(input)
      result.status.should eq("sat")
    end

    it "returns error for malformed SMT-LIB" do
      solver = Chiasmus::Solvers::Z3Solver.new
      input = Chiasmus::Solvers::Z3SolverInput.new(
        type: Chiasmus::Solvers::SolverType::Z3,
        smtlib: "this is not valid SMT-LIB\n"
      )

      result = solver.solve(input)
      result.should be_a(Chiasmus::Solvers::ErrorResult)
    end

    it "handles empty input gracefully" do
      solver = Chiasmus::Solvers::Z3Solver.new
      input = Chiasmus::Solvers::Z3SolverInput.new(
        type: Chiasmus::Solvers::SolverType::Z3,
        smtlib: ""
      )

      result = solver.solve(input)
      result.status.should eq("sat")
    end

    it "strips check-sat and get-model from input" do
      solver = Chiasmus::Solvers::Z3Solver.new
      input = Chiasmus::Solvers::Z3SolverInput.new(
        type: Chiasmus::Solvers::SolverType::Z3,
        smtlib: "(declare-const x Int)\n(assert (> x 0))\n(check-sat)\n(get-model)"
      )

      result = solver.solve(input)
      result.status.should eq("sat")
    end

    it "dispose is a no-op" do
      solver = Chiasmus::Solvers::Z3Solver.new
      solver.dispose # Should not raise
    end
  end
end
