require "../spec_helper"

private def z3_available?
  Process.run("which", ["z3"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
rescue
  false
end

describe "Benchmark: Problem 1 - RBAC Policy Conflict Detection" do
  describe "Traditional" do
    it "detects the auditor read/billing conflict" do
      result = Benchmark::Traditional.solve_rbac(Benchmark::Problems::RBACRules)
      result.has_conflict.should be_true
    end

    it "returns the specific conflicting triple" do
      result = Benchmark::Traditional.solve_rbac(Benchmark::Problems::RBACRules)
      match = result.conflicts.find { |c| c[:role] == "auditor" && c[:action] == "read" && c[:resource] == "billing" }
      match.should_not be_nil
    end

    it "finds exactly one conflict in this ruleset" do
      result = Benchmark::Traditional.solve_rbac(Benchmark::Problems::RBACRules)
      result.conflicts.size.should eq(1)
    end
  end

  describe "Chiasmus (Z3)" do
    it "detects the auditor read/billing conflict" do
      next pending("z3 not installed") unless z3_available?

      input = {
        roles:     Benchmark::Problems::RBACRoles,
        resources: Benchmark::Problems::RBACResources,
        rules:     Benchmark::Problems::RBACRules,
      }
      result = Benchmark::Chiasmus.solve_rbac(input)
      result.has_conflict.should be_true
    end

    it "returns the specific conflicting triple" do
      next pending("z3 not installed") unless z3_available?

      input = {
        roles:     Benchmark::Problems::RBACRoles,
        resources: Benchmark::Problems::RBACResources,
        rules:     Benchmark::Problems::RBACRules,
      }
      result = Benchmark::Chiasmus.solve_rbac(input)
      match = result.conflicts.find { |c| c[:role] == "auditor" && c[:action] == "read" && c[:resource] == "billing" }
      match.should_not be_nil
    end

    it "finds exactly one conflict in this ruleset" do
      next pending("z3 not installed") unless z3_available?

      input = {
        roles:     Benchmark::Problems::RBACRoles,
        resources: Benchmark::Problems::RBACResources,
        rules:     Benchmark::Problems::RBACRules,
      }
      result = Benchmark::Chiasmus.solve_rbac(input)
      result.conflicts.size.should eq(1)
    end
  end
end
