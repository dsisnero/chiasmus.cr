require "../../spec_helper"

private def z3_available? : Bool
  Process.run("which", ["z3"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
rescue
  false
end

describe Chiasmus::Solvers::Z3Solver do
  it "returns sat with a model for satisfiable constraints" do
    next pending("z3 not installed") unless z3_available?

    solver = Chiasmus::Solvers::Z3Solver.new
    result = solver.solve(Chiasmus::Solvers::Z3SolverInput.new(<<-SMT))
      (declare-const x Int)
      (declare-const y Int)
      (assert (> x 0))
      (assert (< y 10))
      (assert (= (+ x y) 7))
    SMT

    result.should be_a(Chiasmus::Solvers::SatResult)
    sat = result.as(Chiasmus::Solvers::SatResult)
    sat.model.has_key?("x").should be_true
    sat.model.has_key?("y").should be_true
    x = sat.model["x"]?
    y = sat.model["y"]?
    x.should_not be_nil
    y.should_not be_nil
    x_value = x.not_nil!.to_i
    y_value = y.not_nil!.to_i
    x_value.should be > 0
    y_value.should be < 10
    (x_value + y_value).should eq(7)
  end

  it "returns unsat for contradictory constraints" do
    next pending("z3 not installed") unless z3_available?

    solver = Chiasmus::Solvers::Z3Solver.new
    result = solver.solve(Chiasmus::Solvers::Z3SolverInput.new(<<-SMT))
      (declare-const x Int)
      (assert (> x 10))
      (assert (< x 5))
    SMT

    result.should be_a(Chiasmus::Solvers::UnsatResult)
  end

  it "returns an error for malformed SMT-LIB" do
    next pending("z3 not installed") unless z3_available?

    solver = Chiasmus::Solvers::Z3Solver.new
    result = solver.solve(Chiasmus::Solvers::Z3SolverInput.new(%((declare-const x Int) (assert (> x "not_a_number")))))

    result.should be_a(Chiasmus::Solvers::ErrorResult)
    result.as(Chiasmus::Solvers::ErrorResult).error.should_not be_empty
  end

  it "strips solver commands it manages internally" do
    next pending("z3 not installed") unless z3_available?

    solver = Chiasmus::Solvers::Z3Solver.new
    result = solver.solve(Chiasmus::Solvers::Z3SolverInput.new(<<-SMT))
      (declare-const x Int)
      (assert (= x 5))
      (check-sat)
      (get-model)
      (get-unsat-core)
    SMT

    result.should be_a(Chiasmus::Solvers::SatResult)
    result.as(Chiasmus::Solvers::SatResult).model["x"]?.should eq("5")
  end

  it "returns an unsat core for named contradictory constraints" do
    next pending("z3 not installed") unless z3_available?

    solver = Chiasmus::Solvers::Z3Solver.new
    result = solver.solve(Chiasmus::Solvers::Z3SolverInput.new(<<-SMT))
      (declare-const x Int)
      (assert (! (> x 10) :named gt10))
      (assert (! (< x 5) :named lt5))
    SMT

    result.should be_a(Chiasmus::Solvers::UnsatResult)
    unsat = result.as(Chiasmus::Solvers::UnsatResult)
    unsat.unsat_core.should_not be_nil
    core = unsat.unsat_core.not_nil!.join(" ")
    core.should match(/gt10|lt5/)
  end

  it "treats empty input as vacuously satisfiable" do
    next pending("z3 not installed") unless z3_available?

    solver = Chiasmus::Solvers::Z3Solver.new
    result = solver.solve(Chiasmus::Solvers::Z3SolverInput.new(""))

    result.should be_a(Chiasmus::Solvers::SatResult)
    result.as(Chiasmus::Solvers::SatResult).model.should be_empty
  end

  it "handles boolean satisfiability" do
    next pending("z3 not installed") unless z3_available?

    solver = Chiasmus::Solvers::Z3Solver.new
    result = solver.solve(Chiasmus::Solvers::Z3SolverInput.new(<<-SMT))
      (declare-const p Bool)
      (declare-const q Bool)
      (assert (or p q))
      (assert (not (and p q)))
    SMT

    result.should be_a(Chiasmus::Solvers::SatResult)
  end

  it "handles custom datatypes" do
    next pending("z3 not installed") unless z3_available?

    solver = Chiasmus::Solvers::Z3Solver.new
    result = solver.solve(Chiasmus::Solvers::Z3SolverInput.new(<<-SMT))
      (declare-datatypes ((Color 0)) (((Red) (Green) (Blue))))
      (declare-const c1 Color)
      (declare-const c2 Color)
      (assert (not (= c1 c2)))
      (assert (not (= c1 Red)))
      (assert (not (= c2 Red)))
    SMT

    result.should be_a(Chiasmus::Solvers::SatResult)
    sat = result.as(Chiasmus::Solvers::SatResult)
    sat.model["c1"]?.should_not be_nil
    sat.model["c2"]?.should_not be_nil
    sat.model["c1"].should_not eq("Red")
    sat.model["c2"].should_not eq("Red")
    sat.model["c1"].should_not eq(sat.model["c2"])
  end

  it "returns unsat core for unnamed contradictory assertions" do
    next pending("z3 not installed") unless z3_available?

    solver = Chiasmus::Solvers::Z3Solver.new
    result = solver.solve(Chiasmus::Solvers::Z3SolverInput.new(<<-SMT))
      (declare-const x Int)
      (assert (> x 10))
      (assert (< x 5))
    SMT

    result.should be_a(Chiasmus::Solvers::UnsatResult)
    unsat = result.as(Chiasmus::Solvers::UnsatResult)
    unsat.unsat_core.should_not be_nil
    unsat.unsat_core.not_nil!.should be_a(Array(String))
  end

  it "does not include unsat_core for SAT results" do
    next pending("z3 not installed") unless z3_available?

    solver = Chiasmus::Solvers::Z3Solver.new
    result = solver.solve(Chiasmus::Solvers::Z3SolverInput.new(<<-SMT))
      (declare-const x Int)
      (assert (> x 0))
      (assert (< x 10))
    SMT

    result.should be_a(Chiasmus::Solvers::SatResult)
  end

  it "returns unsat core for trivially unsat assertion (assert false)" do
    next pending("z3 not installed") unless z3_available?

    solver = Chiasmus::Solvers::Z3Solver.new
    result = solver.solve(Chiasmus::Solvers::Z3SolverInput.new("(assert false)"))

    result.should be_a(Chiasmus::Solvers::UnsatResult)
    unsat = result.as(Chiasmus::Solvers::UnsatResult)
    unsat.unsat_core.should_not be_nil
    unsat.unsat_core.not_nil!.should be_a(Array(String))
  end
end
