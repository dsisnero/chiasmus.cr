require "../../spec_helper"

alias S = Chiasmus::Solvers

private def z3_available? : Bool
  Process.run("which", ["z3"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
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
        fixer = ->(attempt : S::CorrectionAttempt, error : String, round : Int32, result : S::SolverResult?, input : S::SolverInput?) : S::SolverInput? {
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
        fixer = ->(attempt : S::CorrectionAttempt, error : String, round : Int32, result : S::SolverResult?, input : S::SolverInput?) : S::SolverInput? {
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
        fixer = ->(attempt : S::CorrectionAttempt, error : String, round : Int32, result : S::SolverResult?, input : S::SolverInput?) : S::SolverInput? {
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
        result.history[0].result.not_nil!.status.should eq("error")
        result.history[1].result.not_nil!.status.should eq("error")
        result.history[2].result.not_nil!.status.should eq("sat")
      end

      it "hits max rounds on unfixable spec and returns diagnostics" do
        fixer = ->(attempt : S::CorrectionAttempt, error : String, round : Int32, result : S::SolverResult?, input : S::SolverInput?) : S::SolverInput? {
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
        result.history.each { |h| h.result.not_nil!.status.should eq("error") }
      end

      it "correctly distinguishes solver errors from valid UNSAT" do
        fixer = ->(attempt : S::CorrectionAttempt, error : String, round : Int32, result : S::SolverResult?, input : S::SolverInput?) : S::SolverInput? {
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
        fixer = ->(attempt : S::CorrectionAttempt, error : String, round : Int32, result : S::SolverResult?, input : S::SolverInput?) : S::SolverInput? {
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
        fixer = ->(attempt : S::CorrectionAttempt, error : String, round : Int32, result : S::SolverResult?, input : S::SolverInput?) : S::SolverInput? {
          captured_result = result
          nil
        }

        S.correction_loop(
          S::Z3SolverInput.new("(declare-const x Int) (assert (> x \"bad\"))"),
          fixer,
        )

        captured_result.should_not be_nil
        captured_result.try { |r| r.status.should eq("error") }
        captured_result.try { |r| r.is_a?(S::ErrorResult).should be_true }
        captured_result.try { |r| r.as(S::ErrorResult).error.should_not be_empty }
      end
    end

    describe "Prolog" do
      it "passes through a correct Prolog program without correction" do
        fixer = ->(attempt : S::CorrectionAttempt, error : String, round : Int32, result : S::SolverResult?, input : S::SolverInput?) : S::SolverInput? {
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
        fixer = ->(attempt : S::CorrectionAttempt, error : String, round : Int32, result : S::SolverResult?, input : S::SolverInput?) : S::SolverInput? {
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
        fixer = ->(attempt : S::CorrectionAttempt, error : String, r : Int32, result : S::SolverResult?, input : S::SolverInput?) : S::SolverInput? {
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
        result.history[0].result.not_nil!.status.should eq("error")
        result.history[1].result.not_nil!.status.should eq("error")
        result.history[2].result.not_nil!.status.should eq("error")
        result.history[3].result.not_nil!.status.should eq("success")
      end
    end
  end
end
