require "../spec_helper"

describe Chiasmus::Solvers::SolverSession do
  describe ".create" do
    it "creates isolated Z3 sessions with unique IDs" do
      session1 = Chiasmus::Solvers::SolverSession.create("z3")
      session2 = Chiasmus::Solvers::SolverSession.create("z3")

      session1.id.should_not be_empty
      session2.id.should_not be_empty
      session1.id.should_not eq(session2.id)
    end

    it "creates isolated Prolog sessions with unique IDs" do
      session1 = Chiasmus::Solvers::SolverSession.create("prolog")
      session2 = Chiasmus::Solvers::SolverSession.create("prolog")

      session1.id.should_not be_empty
      session2.id.should_not be_empty
      session1.id.should_not eq(session2.id)
    end

    it "assigns unique session IDs" do
      ids = Set(String).new
      5.times do
        session = Chiasmus::Solvers::SolverSession.create("z3")
        ids.add(session.id)
      end
      ids.size.should eq(5)
    end

    it "raises for unknown solver type" do
      expect_raises(Exception) do
        Chiasmus::Solvers::SolverSession.create("unknown")
      end
    end
  end

  describe "#solve" do
    it "delegates to the underlying Z3 solver" do
      session = Chiasmus::Solvers::SolverSession.create("z3")
      input = Chiasmus::Solvers::Z3SolverInput.new(
        type: Chiasmus::Solvers::SolverType::Z3,
        smtlib: "(declare-const x Int)\n(assert (> x 10))\n"
      )

      result = session.solve(input)
      result.status.should eq("sat")
    end
  end

  describe "#dispose" do
    it "calls dispose on the underlying solver" do
      session = Chiasmus::Solvers::SolverSession.create("z3")
      session.dispose # Should not raise
    end
  end
end
