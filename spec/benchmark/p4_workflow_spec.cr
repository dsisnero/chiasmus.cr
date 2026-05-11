require "../spec_helper"

private def swipl_available?
  Process.run("which", ["swipl"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
rescue
  false
end

describe "Benchmark: Problem 4 - Workflow State Machine Validation" do
  input = {
    initial:     Benchmark::Problems::WorkflowInitial,
    states:      Benchmark::Problems::WorkflowStates,
    transitions: Benchmark::Problems::WorkflowTransitions,
  }

  reachable_states = ["draft", "pending_review", "in_review", "approved",
                      "rejected", "published", "archived"]
  has_outgoing = ["draft", "pending_review", "in_review", "approved",
                  "rejected", "published"]

  describe "Traditional" do
    it "identifies 'deleted' as unreachable" do
      result = Benchmark::Traditional.solve_workflow(input)
      result.unreachable_states.should contain("deleted")
    end

    it "identifies 'archived' as a dead-end" do
      result = Benchmark::Traditional.solve_workflow(input)
      result.dead_end_states.should contain("archived")
    end

    it "does not flag reachable states as unreachable" do
      result = Benchmark::Traditional.solve_workflow(input)
      reachable_states.each do |s|
        result.unreachable_states.should_not contain(s)
      end
    end

    it "does not flag states with outgoing transitions as dead-ends" do
      result = Benchmark::Traditional.solve_workflow(input)
      has_outgoing.each do |s|
        result.dead_end_states.should_not contain(s)
      end
    end
  end

  describe "Chiasmus (Prolog)" do
    it "identifies 'deleted' as unreachable" do
      next pending("swipl not installed") unless swipl_available?

      result = Benchmark::Chiasmus.solve_workflow(input)
      result.unreachable_states.should contain("deleted")
    end

    it "identifies 'archived' as a dead-end" do
      next pending("swipl not installed") unless swipl_available?

      result = Benchmark::Chiasmus.solve_workflow(input)
      result.dead_end_states.should contain("archived")
    end

    it "does not flag reachable states as unreachable" do
      next pending("swipl not installed") unless swipl_available?

      result = Benchmark::Chiasmus.solve_workflow(input)
      reachable_states.each do |s|
        result.unreachable_states.should_not contain(s)
      end
    end

    it "does not flag states with outgoing transitions as dead-ends" do
      next pending("swipl not installed") unless swipl_available?

      result = Benchmark::Chiasmus.solve_workflow(input)
      has_outgoing.each do |s|
        result.dead_end_states.should_not contain(s)
      end
    end
  end
end
