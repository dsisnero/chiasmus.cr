require "../../spec_helper"

describe Chiasmus::Solvers do
  describe ".correction_loop" do
    it "converges once the fixer produces a valid z3 input" do
      attempts = [] of String

      fixer = ->(attempt : Chiasmus::Solvers::CorrectionAttempt, error : String, round : Int32, result : Chiasmus::Solvers::SolverResult?, input : Chiasmus::Solvers::SolverInput?) : Chiasmus::Solvers::SolverInput? do
        attempts << error
        Chiasmus::Solvers::Z3SolverInput.new("(declare-const x Int) (assert (= x 5))")
      end

      result = Chiasmus::Solvers.correction_loop(
        Chiasmus::Solvers::Z3SolverInput.new("(declare-const x Int) (assert (> x \"bad\"))"),
        fixer,
        Chiasmus::Solvers::CorrectionLoopOptions.new(max_rounds: 2)
      )

      result.converged.should be_true
      result.rounds.should eq(2)
      result.history.size.should eq(2)
      result.result.should be_a(Chiasmus::Solvers::SatResult)
      attempts.should_not be_empty
    end

    it "stops when the fixer gives up" do
      fixer = ->(attempt : Chiasmus::Solvers::CorrectionAttempt, error : String, round : Int32, result : Chiasmus::Solvers::SolverResult?, input : Chiasmus::Solvers::SolverInput?) : Chiasmus::Solvers::SolverInput? { nil }

      result = Chiasmus::Solvers.correction_loop(
        Chiasmus::Solvers::Z3SolverInput.new("(declare-const x Int) (assert (> x \"bad\"))"),
        fixer,
        Chiasmus::Solvers::CorrectionLoopOptions.new(max_rounds: 3)
      )

      result.converged.should be_false
      result.rounds.should eq(1)
      result.result.should be_a(Chiasmus::Solvers::ErrorResult)
    end
  end
end
