require "../spec_helper"

describe Chiasmus::Formalize do
  describe ".classify_feedback" do
    it "classifies error result with error message" do
      result = Chiasmus::Solvers::ErrorResult.new(error: "parse error at line 1")
      feedback = Chiasmus::Formalize.classify_feedback(result)

      feedback.should contain("Solver error")
      feedback.should contain("parse error")
    end

    it "classifies unsat result with core" do
      result = Chiasmus::Solvers::UnsatResult.new(unsat_core: ["c1", "c2"])
      feedback = Chiasmus::Formalize.classify_feedback(result)

      feedback.should contain("UNSAT")
      feedback.should contain("c1")
      feedback.should contain("c2")
      feedback.should contain("conflicting")
    end

    it "classifies unsat result without core" do
      result = Chiasmus::Solvers::UnsatResult.new(unsat_core: nil)
      feedback = Chiasmus::Formalize.classify_feedback(result)

      feedback.should contain("UNSAT")
      feedback.should contain("over-constrained")
    end

    it "classifies unsat result with empty core" do
      result = Chiasmus::Solvers::UnsatResult.new(unsat_core: [] of String)
      feedback = Chiasmus::Formalize.classify_feedback(result)

      feedback.should contain("UNSAT")
      feedback.should contain("over-constrained")
    end

    it "classifies sat result with model" do
      result = Chiasmus::Solvers::SatResult.new(model: {"x" => "42", "y" => "true"})
      feedback = Chiasmus::Formalize.classify_feedback(result)

      feedback.should contain("SAT")
      feedback.should contain("x")
      feedback.should contain("42")
    end

    it "classifies sat result with empty model" do
      result = Chiasmus::Solvers::SatResult.new(model: {} of String => String)
      feedback = Chiasmus::Formalize.classify_feedback(result)

      feedback.should contain("SAT")
      feedback.should contain("trivially")
    end

    it "classifies prolog success with answers" do
      answers = [
        Chiasmus::Solvers::PrologAnswer.new(
          bindings: {"X" => "bob"},
          formatted: "X = bob"
        ),
      ]
      result = Chiasmus::Solvers::SuccessResult.new(answers: answers)
      feedback = Chiasmus::Formalize.classify_feedback(result)

      feedback.should contain("Prolog")
      feedback.should contain("bob")
    end

    it "classifies prolog success with no answers" do
      result = Chiasmus::Solvers::SuccessResult.new(answers: [] of Chiasmus::Solvers::PrologAnswer)
      feedback = Chiasmus::Formalize.classify_feedback(result)

      feedback.should contain("No Prolog solutions")
    end

    it "classifies unknown result" do
      result = Chiasmus::Solvers::UnknownResult.new
      feedback = Chiasmus::Formalize.classify_feedback(result)

      feedback.should contain("UNKNOWN")
      feedback.should contain("decidable")
    end
  end
end
