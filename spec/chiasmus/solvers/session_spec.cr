require "../../spec_helper"

private def z3_available? : Bool
  Process.run("which", ["z3"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
rescue
  false
end

private def swipl_available? : Bool
  Process.run("which", ["swipl"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
rescue
  false
end

describe Chiasmus::Solvers::SolverSession do
  it "creates isolated Z3 sessions with unique IDs" do
    next pending("z3 not installed") unless z3_available?

    s1 = Chiasmus::Solvers::SolverSession.create("z3")
    s2 = Chiasmus::Solvers::SolverSession.create("z3")

    begin
      s1.id.should_not eq(s2.id)

      r1 = s1.solve(Chiasmus::Solvers::Z3SolverInput.new("(declare-const x Int)\n(assert (= x 42))"))
      r2 = s2.solve(Chiasmus::Solvers::Z3SolverInput.new("(declare-const x Int)\n(assert (= x 99))"))

      r1.status.should eq("sat")
      r2.status.should eq("sat")
      r1.as(Chiasmus::Solvers::SatResult).model["x"].should eq("42")
      r2.as(Chiasmus::Solvers::SatResult).model["x"].should eq("99")
    ensure
      s1.dispose
      s2.dispose
    end
  end

  it "creates isolated Prolog sessions with unique IDs" do
    next pending("swipl not installed") unless swipl_available?

    s1 = Chiasmus::Solvers::SolverSession.create("prolog")
    s2 = Chiasmus::Solvers::SolverSession.create("prolog")

    begin
      s1.id.should_not eq(s2.id)

      r1 = s1.solve(Chiasmus::Solvers::PrologSolverInput.new("fact(a).", "fact(X)."))
      r2 = s2.solve(Chiasmus::Solvers::PrologSolverInput.new("fact(b). fact(c).", "fact(X)."))

      r1.status.should eq("success")
      r2.status.should eq("success")
      r1.as(Chiasmus::Solvers::SuccessResult).answers.size.should eq(1)
      r1.as(Chiasmus::Solvers::SuccessResult).answers.first.bindings["X"].should eq("a")
      r2.as(Chiasmus::Solvers::SuccessResult).answers.size.should eq(2)
    ensure
      s1.dispose
      s2.dispose
    end
  end

  it "runs Z3 and Prolog concurrently without interference" do
    next pending("z3 not installed") unless z3_available?
    next pending("swipl not installed") unless swipl_available?

    z3_session = Chiasmus::Solvers::SolverSession.create("z3")
    pl_session = Chiasmus::Solvers::SolverSession.create("prolog")

    begin
      z3_input = Chiasmus::Solvers::Z3SolverInput.new(<<-SMT)
        (declare-const a Int)
        (declare-const b Int)
        (assert (= (+ a b) 10))
        (assert (> a 0))
        (assert (> b 0))
      SMT
      pl_input = Chiasmus::Solvers::PrologSolverInput.new(<<-PROLOG, "add(s(s(0)), s(s(s(0))), R).")
        add(0, Y, Y).
        add(s(X), Y, s(Z)) :- add(X, Y, Z).
      PROLOG

      z3_channel = Channel(Chiasmus::Solvers::SolverResult).new(1)
      pl_channel = Channel(Chiasmus::Solvers::SolverResult).new(1)

      spawn { z3_channel.send(z3_session.solve(z3_input)) }
      spawn { pl_channel.send(pl_session.solve(pl_input)) }

      z3_result = z3_channel.receive
      pl_result = pl_channel.receive

      z3_result.status.should eq("sat")
      pl_result.status.should eq("success")
      a_val = z3_result.as(Chiasmus::Solvers::SatResult).model["a"]
      b_val = z3_result.as(Chiasmus::Solvers::SatResult).model["b"]
      (a_val.to_i + b_val.to_i).should eq(10)
      pl_result.as(Chiasmus::Solvers::SuccessResult).answers.first.bindings["R"].should eq("s(s(s(s(s(0)))))")
    ensure
      z3_session.dispose
      pl_session.dispose
    end
  end

  it "assigns unique session IDs" do
    ids = Set(String).new
    sessions = [] of Chiasmus::Solvers::SolverSession

    begin
      5.times do
        s = Chiasmus::Solvers::SolverSession.create("prolog")
        sessions << s
        ids << s.id
      end
      ids.size.should eq(5)
    ensure
      sessions.each(&.dispose)
    end
  end
end
