require "../../spec_helper"
require "file_utils"

private def z3_available? : Bool
  Process.run("which", ["z3"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
rescue
  false
end

# A deterministic stand-in for `z3 -smt2 -in`.  Each `(reset)` ends one solver
# request: requests containing HANG deliberately produce no response, while all
# others emit the two sentinels and a minimal SAT response expected by Z3Solver.
private def fake_z3_command : {String, String}
  directory = File.join(Dir.tempdir, "chiasmus-fake-z3-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(directory)
  command = File.join(directory, "z3")
  File.write(command, <<-'SCRIPT')
#!/bin/sh
request=''
while IFS= read -r line; do
  request="$request
$line"
  case "$line" in
    *'(reset)'*)
      case "$request" in
        *HANG*) sleep 10 ;;
        *)
          printf '%s\n' '<<<Z3_DONE>>>' 'sat' '(' ')' '<<<Z3_DONE>>>'
          ;;
      esac
      request=''
      ;;
  esac
done
SCRIPT
  File.chmod(command, 0o755)
  {directory, command}
end

describe Chiasmus::Solvers::Z3Solver do
  it "times out a hung request, resets its process, and recovers on the next request" do
    directory, command = fake_z3_command
    solver = Chiasmus::Solvers::Z3Solver.new(command: command, timeout: 250.milliseconds)

    begin
      started_at = Time.instant
      timed_out = solver.solve(Chiasmus::Solvers::Z3SolverInput.new("; HANG"))

      timed_out.should be_a(Chiasmus::Solvers::ErrorResult)
      timed_out.as(Chiasmus::Solvers::ErrorResult).error.should match(/timed out/i)
      (Time.instant - started_at).should be < 500.milliseconds

      recovered = solver.solve(Chiasmus::Solvers::Z3SolverInput.new("(assert true)"))
      recovered.should be_a(Chiasmus::Solvers::SatResult)
    ensure
      solver.dispose
      Chiasmus::Solvers::Z3Process.reset
      FileUtils.rm_rf(directory)
    end
  end

  it "serializes concurrent requests through one Z3 runtime without losing responses" do
    directory, command = fake_z3_command
    # This checks actor serialization, not timeout enforcement. Under a
    # threaded suite the process reader can be scheduled behind other specs,
    # so use a budget that covers scheduler contention; the hung-request case
    # above remains the 250 ms timeout regression.
    solver = Chiasmus::Solvers::Z3Solver.new(command: command, timeout: 2.seconds)
    results = Channel(Chiasmus::Solvers::SolverResult).new(8)

    begin
      8.times do |index|
        spawn do
          results.send(solver.solve(Chiasmus::Solvers::Z3SolverInput.new("(assert true) ; request #{index}")))
        end
      end

      8.times do
        select
        when result = results.receive
          result.should be_a(Chiasmus::Solvers::SatResult)
        when timeout 2.seconds
          fail "concurrent Z3 request did not receive a response"
        end
      end
    ensure
      solver.dispose
      Chiasmus::Solvers::Z3Process.reset
      FileUtils.rm_rf(directory)
    end
  end

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
    if x && y
      x_value = x.to_i
      y_value = y.to_i
      x_value.should be > 0
      y_value.should be < 10
      (x_value + y_value).should eq(7)
    end
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
    if core = unsat.unsat_core
      core.join(" ").should match(/gt10|lt5/)
    else
      fail("expected unsat_core to not be nil")
    end
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
    if core = unsat.unsat_core
      core.should be_a(Array(String))
    else
      fail("expected unsat_core to not be nil")
    end
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
    if core = unsat.unsat_core
      core.should be_a(Array(String))
    else
      fail("expected unsat_core to not be nil")
    end
  end
end
