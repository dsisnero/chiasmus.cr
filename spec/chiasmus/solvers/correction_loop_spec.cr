require "../../spec_helper"

alias S = Chiasmus::Solvers

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

describe Chiasmus::Solvers do
  describe ".correction_loop" do
    describe "Z3" do
      before_all do
        unless z3_available?
          pending "z3 not installed"
        end
      end

      it "passes through a correct spec without correction" do
        fixer = ->(_attempt : S::CorrectionAttempt, _error : String, _round : Int32, _result : S::SolverResult?, _input : S::SolverInput?) : S::SolverInput? {
          raise "Fixer should not be called for correct input"
        }

        result = S.correction_loop(
          S::Z3SolverInput.new("(declare-const x Int) (assert (= x 42))"),
          fixer,
        )

        result.converged.should be_true
        result.rounds.should eq(1)
        result.result.status.should eq("sat")
        result.history.size.should eq(1)
      end

      it "fixes a minor syntax error within 2 rounds" do
        fixer = ->(_attempt : S::CorrectionAttempt, _error : String, _round : Int32, _result : S::SolverResult?, _input : S::SolverInput?) : S::SolverInput? {
          S::Z3SolverInput.new("(declare-const x Int) (assert (> x 5))")
        }

        result = S.correction_loop(
          S::Z3SolverInput.new("(declare-const x Int) (assert (> x \"five\"))"),
          fixer,
        )

        result.converged.should be_true
        result.rounds.should eq(2)
        result.result.status.should eq("sat")
      end

      it "handles multi-round fixes for semantic errors" do
        fix_attempt = 0
        fixer = ->(_attempt : S::CorrectionAttempt, _error : String, _round : Int32, _result : S::SolverResult?, _input : S::SolverInput?) : S::SolverInput? {
          fix_attempt += 1
          if fix_attempt == 1
            S::Z3SolverInput.new("(declare-const x Int) (assert (> x \"ten\"))")
          elsif fix_attempt == 2
            S::Z3SolverInput.new("(declare-const x Int) (assert (> x 10))")
          else
            nil
          end
        }

        result = S.correction_loop(
          S::Z3SolverInput.new("(declare-const x Int) (assert (> x \"bad\"))"),
          fixer,
        )

        result.converged.should be_true
        result.rounds.should eq(3)
        result.history.size.should eq(3)
        h0r = result.history[0].result || raise("nil h0r")
        h0r.status.should eq("error")
        h1r = result.history[1].result || raise("nil h1r")
        h1r.status.should eq("error")
        h2r = result.history[2].result || raise("nil h2r")
        h2r.status.should eq("sat")
      end

      it "hits max rounds on unfixable spec and returns diagnostics" do
        fixer = ->(_attempt : S::CorrectionAttempt, _error : String, _round : Int32, _result : S::SolverResult?, _input : S::SolverInput?) : S::SolverInput? {
          S::Z3SolverInput.new("(declare-const x Int) (assert (> x \"always_broken\"))")
        }

        result = S.correction_loop(
          S::Z3SolverInput.new("(declare-const x Int) (assert (> x \"broken\"))"),
          fixer,
          S::CorrectionLoopOptions.new(max_rounds: 3),
        )

        result.converged.should be_false
        result.rounds.should eq(3)
        result.result.status.should eq("error")
        result.history.size.should eq(3)
        result.history.each do |entry|
          entry_result = entry.result || raise("nil entry_result")
          entry_result.should_not be_nil
          entry_result.status.should eq("error")
        end
      end

      it "correctly distinguishes solver errors from valid UNSAT" do
        fixer = ->(_attempt : S::CorrectionAttempt, _error : String, _round : Int32, _result : S::SolverResult?, _input : S::SolverInput?) : S::SolverInput? {
          S::Z3SolverInput.new("(declare-const x Int) (assert (> x 10)) (assert (< x 5))")
        }

        result = S.correction_loop(
          S::Z3SolverInput.new("(declare-const x Int) (assert (> x \"bad\"))"),
          fixer,
        )

        result.converged.should be_true
        result.rounds.should eq(2)
        result.result.status.should eq("unsat")
      end

      it "stops early when fixer gives up (returns null)" do
        fixer_calls = 0
        fixer = ->(_attempt : S::CorrectionAttempt, _error : String, _round : Int32, _result : S::SolverResult?, _input : S::SolverInput?) : S::SolverInput? {
          fixer_calls += 1
          nil
        }

        result = S.correction_loop(
          S::Z3SolverInput.new("(declare-const x Int) (assert (> x \"bad\"))"),
          fixer,
          S::CorrectionLoopOptions.new(max_rounds: 5),
        )

        result.converged.should be_false
        fixer_calls.should eq(1)
        result.rounds.should eq(1)
      end
    end

    describe "enhanced feedback" do
      it "passes full SolverResult to fixer via result parameter" do
        captured_result = nil
        fixer = ->(_attempt : S::CorrectionAttempt, _error : String, _round : Int32, result : S::SolverResult?, _input : S::SolverInput?) : S::SolverInput? {
          captured_result = result
          nil
        }

        S.correction_loop(
          S::Z3SolverInput.new("(declare-const x Int) (assert (> x \"bad\"))"),
          fixer,
        )

        captured_result.should_not be_nil
        if cres = captured_result
          cres.status.should eq("error")
          cres.is_a?(S::ErrorResult).should be_true
          cres.as(S::ErrorResult).error.should_not be_empty
        end
      end
    end

    describe "Prolog" do
      before_all do
        unless swipl_available?
          pending "swipl not installed"
        end
      end

      it "passes through a correct Prolog program without correction" do
        fixer = ->(_attempt : S::CorrectionAttempt, _error : String, _round : Int32, _result : S::SolverResult?, _input : S::SolverInput?) : S::SolverInput? {
          raise "Should not be called"
        }

        result = S.correction_loop(
          S::PrologSolverInput.new("parent(tom, bob).", "parent(tom, X)."),
          fixer,
        )

        result.converged.should be_true
        result.rounds.should eq(1)
        result.result.status.should eq("success")
      end

      it "fixes a malformed Prolog program" do
        fixer = ->(_attempt : S::CorrectionAttempt, _error : String, _round : Int32, _result : S::SolverResult?, _input : S::SolverInput?) : S::SolverInput? {
          S::PrologSolverInput.new("parent(tom, bob).", "parent(tom, X).")
        }

        result = S.correction_loop(
          S::PrologSolverInput.new("parent(tom bob).", "parent(tom, X)."),
          fixer,
        )

        result.converged.should be_true
        result.rounds.should eq(2)
        result.result.status.should eq("success")
      end

      it "provides error history for debugging" do
        round = 0
        fixer = ->(_attempt : S::CorrectionAttempt, _error : String, _round : Int32, _result : S::SolverResult?, _input : S::SolverInput?) : S::SolverInput? {
          round += 1
          if round < 3
            S::PrologSolverInput.new("parent(tom bob).", "parent(tom, X).")
          else
            S::PrologSolverInput.new("parent(tom, bob).", "parent(tom, X).")
          end
        }

        result = S.correction_loop(
          S::PrologSolverInput.new("parent(tom bob).", "parent(tom, X)."),
          fixer,
        )

        result.converged.should be_true
        result.rounds.should eq(4)
        h0 = result.history[0].result || raise("nil h0")
        h0.status.should eq("error")
        h1 = result.history[1].result || raise("nil h1")
        h1.status.should eq("error")
        h2 = result.history[2].result || raise("nil h2")
        h2.status.should eq("error")
        h3 = result.history[3].result || raise("nil h3")
        h3.status.should eq("success")
      end
    end
  end
end
