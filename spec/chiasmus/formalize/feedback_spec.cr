require "../../spec_helper"

describe Chiasmus::Formalize do
  describe ".classify_feedback" do
    it "classifies error result" do
      feedback = Chiasmus::Formalize.classify_feedback(
        Chiasmus::Solvers::ErrorResult.new("type mismatch at line 3")
      )

      feedback.should contain("type mismatch")
    end

    it "classifies unsat result with core" do
      feedback = Chiasmus::Formalize.classify_feedback(
        Chiasmus::Solvers::UnsatResult.new(["gt10", "lt5"])
      )

      feedback.should match(/gt10/)
      feedback.should match(/lt5/)
      feedback.should match(/conflict/i)
    end

    it "classifies unsat result without core" do
      feedback = Chiasmus::Formalize.classify_feedback(
        Chiasmus::Solvers::UnsatResult.new
      )

      feedback.should match(/contradictory|over-constrained/i)
    end

    it "classifies sat result with model" do
      feedback = Chiasmus::Formalize.classify_feedback(
        Chiasmus::Solvers::SatResult.new({"x" => "5", "y" => "3"})
      )

      feedback.should contain("5")
      feedback.should contain("3")
    end

    it "classifies prolog success with no answers" do
      feedback = Chiasmus::Formalize.classify_feedback(
        Chiasmus::Solvers::SuccessResult.new([] of Chiasmus::Solvers::PrologAnswer)
      )

      feedback.should match(/no.*solution|no.*answer/i)
    end

    it "classifies prolog success with answers" do
      answers = [
        Chiasmus::Solvers::PrologAnswer.new({"X" => "bob"}, "X = bob"),
      ]
      feedback = Chiasmus::Formalize.classify_feedback(
        Chiasmus::Solvers::SuccessResult.new(answers)
      )

      feedback.should contain("1")
      feedback.should contain("X = bob")
    end

    it "classifies unknown result" do
      feedback = Chiasmus::Formalize.classify_feedback(
        Chiasmus::Solvers::UnknownResult.new
      )

      feedback.should match(/unknown/i)
    end
  end
end
