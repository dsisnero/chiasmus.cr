private def z3_available?
  Process.run("which", ["z3"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
rescue
  false
end

private def swipl_available?
  Process.run("which", ["swipl"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
rescue
  false
end

describe "Dogfood: realistic problem domains" do
  describe "Z3: Policy contradiction detection" do
    it "detects that 3 tasks cannot fit in 2 non-overlapping slots" do
      next pending("z3 not installed") unless z3_available?

      solver = Chiasmus::Solvers::Z3Solver.new
      result = solver.solve(Chiasmus::Solvers::Z3SolverInput.new(<<-SMT))
        (declare-const task1_slot Int)
        (declare-const task2_slot Int)
        (declare-const task3_slot Int)
        (assert (or (= task1_slot 1) (= task1_slot 2)))
        (assert (or (= task2_slot 1) (= task2_slot 2)))
        (assert (or (= task3_slot 1) (= task3_slot 2)))
        (assert (not (= task1_slot task2_slot)))
        (assert (not (= task2_slot task3_slot)))
        (assert (not (= task1_slot task3_slot)))
      SMT

      result.should be_a(Chiasmus::Solvers::UnsatResult)
    end

    it "finds valid dependency version resolution" do
      next pending("z3 not installed") unless z3_available?

      solver = Chiasmus::Solvers::Z3Solver.new
      result = solver.solve(Chiasmus::Solvers::Z3SolverInput.new(<<-SMT))
        (declare-const lib_a Int)
        (declare-const lib_b Int)
        (declare-const lib_c Int)
        (assert (and (>= lib_a 1) (<= lib_a 3)))
        (assert (and (>= lib_b 1) (<= lib_b 2)))
        (assert (and (>= lib_c 1) (<= lib_c 3)))
        (assert (>= lib_a 2))
        (assert (=> (= lib_a 3) (>= lib_b 2)))
        (assert (=> (= lib_b 2) (>= lib_c 2)))
        (assert (not (and (= lib_c 3) (= lib_a 2))))
      SMT

      result.should be_a(Chiasmus::Solvers::SatResult)
      sat = result.as(Chiasmus::Solvers::SatResult)
      a = sat.model["lib_a"].not_nil!.to_i
      b = sat.model["lib_b"].not_nil!.to_i
      c = sat.model["lib_c"].not_nil!.to_i
      a.should be >= 2
      b.should be >= 1
      c.should be >= 1
      (c == 3 && a == 2).should be_false
    end

    it "detects contradictory firewall rules" do
      next pending("z3 not installed") unless z3_available?

      solver = Chiasmus::Solvers::Z3Solver.new
      result = solver.solve(Chiasmus::Solvers::Z3SolverInput.new(<<-SMT))
        (declare-datatypes ((Verdict 0)) (((Allow) (Deny))))
        (declare-const port Int)
        (declare-const rule1_verdict Verdict)
        (declare-const rule2_verdict Verdict)

        (assert (=> (and (>= port 80) (<= port 443))
                   (= rule1_verdict Allow)))
        (assert (=> (and (>= port 100) (<= port 200))
                   (= rule2_verdict Deny)))

        (assert (= rule1_verdict Allow))
        (assert (= rule2_verdict Deny))
        (assert (and (>= port 80) (<= port 443)))
        (assert (and (>= port 100) (<= port 200)))
      SMT

      result.should be_a(Chiasmus::Solvers::SatResult)
      sat = result.as(Chiasmus::Solvers::SatResult)
      port = sat.model["port"].not_nil!.to_i
      port.should be >= 100
      port.should be <= 200
    end
  end

  describe "Prolog: Rule-based reasoning" do
    it "derives transitive permissions through role hierarchy" do
      next pending("swipl not installed") unless swipl_available?

      solver = Chiasmus::Solvers::PrologSolver.new
      result = solver.solve(<<-PROLOG, "can(alice, Action).")
        role(alice, admin).
        role(bob, editor).
        role(carol, viewer).

        inherits(admin, editor).
        inherits(editor, viewer).

        has_role(User, Role) :- role(User, Role).
        has_role(User, Role) :- role(User, R), inherits(R, Mid), has_role_chain(Mid, Role).

        has_role_chain(Role, Role).
        has_role_chain(Start, End) :- inherits(Start, Mid), has_role_chain(Mid, End).

        can(User, read) :- has_role(User, viewer).
        can(User, read) :- has_role(User, editor).
        can(User, read) :- has_role(User, admin).
        can(User, write) :- has_role(User, editor).
        can(User, write) :- has_role(User, admin).
        can(User, delete) :- has_role(User, admin).
      PROLOG

      result.should be_a(Chiasmus::Solvers::SuccessResult)
      actions = result.as(Chiasmus::Solvers::SuccessResult).answers.map { |a| a.bindings["Action"]? }.compact
      actions.should contain("read")
      actions.should contain("write")
      actions.should contain("delete")
    end

    it "checks data lineage / reachability" do
      next pending("swipl not installed") unless swipl_available?

      solver = Chiasmus::Solvers::PrologSolver.new
      result = solver.solve(<<-PROLOG, "reaches(user_input, Where).")
        flows(user_input, api_handler).
        flows(api_handler, validator).
        flows(validator, database).
        flows(api_handler, logger).
        flows(logger, log_file).

        reaches(A, B) :- flows(A, B).
        reaches(A, B) :- flows(A, Mid), reaches(Mid, B).
      PROLOG

      result.should be_a(Chiasmus::Solvers::SuccessResult)
      destinations = result.as(Chiasmus::Solvers::SuccessResult).answers.map { |a| a.bindings["Where"]? }.compact
      destinations.should contain("database")
      destinations.should contain("log_file")
      destinations.should contain("api_handler")
    end

    it "validates workflow state machine transitions" do
      next pending("swipl not installed") unless swipl_available?

      solver = Chiasmus::Solvers::PrologSolver.new
      result = solver.solve(<<-PROLOG, "path(draft, published).")
        transition(draft, submit, pending_review).
        transition(pending_review, approve, approved).
        transition(approved, publish, published).

        path(A, B) :- transition(A, _, B).
        path(A, B) :- transition(A, _, X), path(X, B).
      PROLOG

      result.should be_a(Chiasmus::Solvers::SuccessResult)
      result.as(Chiasmus::Solvers::SuccessResult).answers.size.should be >= 1
    end
  end
end
