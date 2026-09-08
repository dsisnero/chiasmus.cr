require "../../spec_helper"
require "../../../src/chiasmus/solvers/types"
require "../../../src/chiasmus/solvers/session"
require "../../../src/chiasmus/solvers/prolog_solver"

private def swipl_available? : Bool
  Process.run("which", ["swipl"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
rescue
  false
end

describe Chiasmus::Solvers::SolverSession do
  describe ".create" do
    it "keeps Z3 sessions isolated when one session is disposed" do
      next pending("z3 not installed") unless Process.run("which", ["z3"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?

      first = Chiasmus::Solvers::SolverSession.create("z3")
      second = Chiasmus::Solvers::SolverSession.create("z3")

      begin
        first.id.should_not eq(second.id)
        first.solve(Chiasmus::Solvers::Z3SolverInput.new("(assert true)")).should be_a(Chiasmus::Solvers::SatResult)
        first.dispose

        second.solve(Chiasmus::Solvers::Z3SolverInput.new("(assert true)")).should be_a(Chiasmus::Solvers::SatResult)
      ensure
        first.dispose
        second.dispose
      end
    end

    it "generates unique session IDs" do
      s1 = Chiasmus::Solvers::SolverSession.create("prolog")
      s2 = Chiasmus::Solvers::SolverSession.create("prolog")
      raise "s1 nil" unless s1
      raise "s2 nil" unless s2

      s1.id.should_not eq(s2.id)
    ensure
      s1.try(&.dispose)
      s2.try(&.dispose)
    end

    it "each session spawns its own worker fiber" do
      s = Chiasmus::Solvers::SolverSession.create("prolog")
      raise "expected non-nil session" unless s
      chan = Channel(String).new

      spawn do
        result = s.solve(Chiasmus::Solvers::PrologSolverInput.new("parent(tom, bob).", "parent(tom, X)."))
        chan.send(result.status)
      end

      status = chan.receive
      status.should eq("success")
    ensure
      s.try(&.dispose)
    end

    it "two sessions run concurrently without deadlock" do
      unless swipl_available?
        pending "swipl not installed"
      end

      s1 = Chiasmus::Solvers::SolverSession.create("prolog")
      s2 = Chiasmus::Solvers::SolverSession.create("prolog")
      raise "s1 nil" unless s1
      raise "s2 nil" unless s2

      ch1 = Channel({String, String}).new
      ch2 = Channel({String, String}).new

      spawn do
        r = s1.solve(Chiasmus::Solvers::PrologSolverInput.new("parent(tom, bob).", "parent(tom, X)."))
        ch1.send({s1.id, r.status})
      end

      spawn do
        r = s2.solve(Chiasmus::Solvers::PrologSolverInput.new("parent(jim, ann).", "parent(jim, X)."))
        ch2.send({s2.id, r.status})
      end

      id1, st1 = ch1.receive
      id2, st2 = ch2.receive

      id1.should_not eq(id2)
      st1.should eq("success")
      st2.should eq("success")
    ensure
      s1.try(&.dispose)
      s2.try(&.dispose)
    end

    it "each session has its own worker channel, not shared singleton" do
      unless swipl_available?
        pending "swipl not installed"
      end

      s = Chiasmus::Solvers::SolverSession.create("prolog")
      raise "expected non-nil session" unless s

      # Solve works through the session's own fiber
      result = s.solve(Chiasmus::Solvers::PrologSolverInput.new("edge(a,b).", "edge(a,X)."))
      result.status.should eq("success")

      # After dispose, session is dead — new solve should fail
      s.dispose

      expect_raises(Exception) do
        s.solve(Chiasmus::Solvers::PrologSolverInput.new("edge(a,b).", "edge(a,X)."))
      end
    end

    it "queues multiple async prolog requests on the session worker" do
      unless swipl_available?
        pending "swipl not installed"
      end

      s = Chiasmus::Solvers::SolverSession.create("prolog")
      raise "expected non-nil session" unless s

      r1 = s.solve_async(Chiasmus::Solvers::PrologSolverInput.new("parent(tom, bob).", "parent(tom, X)."))
      r2 = s.solve_async(Chiasmus::Solvers::PrologSolverInput.new("parent(jim, ann).", "parent(jim, X)."))

      result1 = r1.receive
      result2 = r2.receive

      result1.status.should eq("success")
      result2.status.should eq("success")
    ensure
      s.try(&.dispose)
    end
  end
end
