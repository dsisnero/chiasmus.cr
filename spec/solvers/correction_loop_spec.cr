require "../spec_helper"

private def make_z3_input(smtlib : String)
  Chiasmus::Solvers::Z3SolverInput.new(
    type: Chiasmus::Solvers::SolverType::Z3,
    smtlib: smtlib
  )
end

describe Chiasmus::Solvers do
  describe ".correction_loop" do
    it "passes through a correct spec without correction" do
      input = make_z3_input("(declare-const x Int)\n(assert (> x 10))\n")
      fixer = ->(attempt : Chiasmus::Solvers::CorrectionAttempt, error : String, round : Int32, result : Chiasmus::Solvers::SolverResult?, current : Chiasmus::Solvers::SolverInput?) : Chiasmus::Solvers::SolverInput? { nil }

      result = Chiasmus::Solvers.correction_loop(input, fixer)

      result.converged.should be_true
      result.rounds.should eq(1)
      result.history.size.should eq(1)
      result.history.first.result.should_not be_nil
    end

    it "hits max rounds on unfixable spec and returns diagnostics" do
      input = make_z3_input("this is not valid SMT-LIB\n")

      # Fixer always returns the same broken input
      fixer = ->(attempt : Chiasmus::Solvers::CorrectionAttempt, error : String, round : Int32, result : Chiasmus::Solvers::SolverResult?, current : Chiasmus::Solvers::SolverInput?) : Chiasmus::Solvers::SolverInput? {
        current
      }

      result = Chiasmus::Solvers.correction_loop(
        input, fixer,
        Chiasmus::Solvers::CorrectionLoopOptions.new(max_rounds: 3)
      )

      result.converged.should be_false
      result.rounds.should be > 0
      result.history.size.should be > 0
    end

    it "stops early when fixer gives up (returns nil)" do
      input = make_z3_input("this is not valid SMT-LIB\n")

      # Fixer gives up immediately
      fixer = ->(attempt : Chiasmus::Solvers::CorrectionAttempt, error : String, round : Int32, result : Chiasmus::Solvers::SolverResult?, current : Chiasmus::Solvers::SolverInput?) : Chiasmus::Solvers::SolverInput? { nil }

      result = Chiasmus::Solvers.correction_loop(
        input, fixer,
        Chiasmus::Solvers::CorrectionLoopOptions.new(max_rounds: 5)
      )

      result.converged.should be_false
      result.rounds.should be > 0
    end

    it "records full correction history in the result" do
      input = make_z3_input("this is not valid SMT-LIB\n")

      fixer = ->(attempt : Chiasmus::Solvers::CorrectionAttempt, error : String, round : Int32, result : Chiasmus::Solvers::SolverResult?, current : Chiasmus::Solvers::SolverInput?) : Chiasmus::Solvers::SolverInput? {
        current
      }

      result = Chiasmus::Solvers.correction_loop(
        input, fixer,
        Chiasmus::Solvers::CorrectionLoopOptions.new(max_rounds: 2)
      )

      result.history.size.should be > 0
      result.history.each do |attempt|
        attempt.input.should_not be_nil
      end
    end

    it "correctly distinguishes solver errors from valid results" do
      # Valid spec that returns sat (not an error)
      input = make_z3_input("(declare-const x Int)\n(assert (> x 0))\n")
      call_count = 0
      fixer = ->(attempt : Chiasmus::Solvers::CorrectionAttempt, error : String, round : Int32, result : Chiasmus::Solvers::SolverResult?, current : Chiasmus::Solvers::SolverInput?) : Chiasmus::Solvers::SolverInput? {
        call_count += 1
        nil
      }

      result = Chiasmus::Solvers.correction_loop(input, fixer)

      result.converged.should be_true
      call_count.should eq(0) # fixer should never be called for valid spec
    end

    it "passes SolverResult to fixer via result parameter" do
      input = make_z3_input("this is not valid SMT-LIB\n")
      received_result = false

      fixer = ->(attempt : Chiasmus::Solvers::CorrectionAttempt, error : String, round : Int32, result : Chiasmus::Solvers::SolverResult?, current : Chiasmus::Solvers::SolverInput?) : Chiasmus::Solvers::SolverInput? {
        received_result = !result.nil?
        nil
      }

      Chiasmus::Solvers.correction_loop(input, fixer)
      received_result.should be_true
    end

    it "defaults to 5 max rounds" do
      opts = Chiasmus::Solvers::CorrectionLoopOptions.new
      opts.max_rounds.should eq(5)
    end
  end
end
