require "../../spec_helper"
require "file_utils"

def with_formalize_engine(&)
  dir = File.join(Dir.tempdir, "chiasmus-formalize-engine-spec-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(dir)
  library = Chiasmus::Skills::Library.create(dir)
  engine = Chiasmus::Formalize::Engine(Chiasmus::LLM::MockCompletionModel).new(
    library,
    Chiasmus::LLM::MockAdapter.create_agent
  )

  begin
    yield engine, library
  ensure
    library.close
    FileUtils.rm_rf(dir)
  end
end

describe Chiasmus::Formalize::Engine(Chiasmus::LLM::MockCompletionModel) do
  describe "#formalize" do
    it "selects the policy contradiction template for access control conflicts" do
      with_formalize_engine do |engine, _library|
        result = engine.formalize(
          "Check if our RBAC rules can ever allow and deny the same user accessing the same resource"
        )

        result.template.name.should eq("policy-contradiction")
        result.template.solver.should eq(Chiasmus::Solvers::SolverType::Z3)
        result.instructions.should contain("SLOT")
      end
    end

    it "selects a prolog template for rule inference problems" do
      with_formalize_engine do |engine, _library|
        result = engine.formalize(
          "Given these business rules and employee data, determine who is eligible for promotion"
        )

        result.template.solver.should eq(Chiasmus::Solvers::SolverType::Prolog)
        {"rule-inference", "permission-derivation"}.should contain(result.template.name)
      end
    end

    it "selects graph reachability for data flow problems" do
      with_formalize_engine do |engine, _library|
        engine.formalize(
          "Can user input reach the database through any chain of function calls?"
        ).template.name.should eq("graph-reachability")
      end
    end

    it "selects constraint satisfaction for dependency problems" do
      with_formalize_engine do |engine, _library|
        engine.formalize(
          "Find compatible versions for these npm packages given their peer dependency constraints"
        ).template.name.should eq("constraint-satisfaction")
      end
    end

    it "includes normalization guidance in instructions" do
      with_formalize_engine do |engine, _library|
        result = engine.formalize(
          "Check if our Kubernetes RBAC roles have conflicting permissions"
        )

        result.instructions.should contain("Kubernetes")
      end
    end
  end
end
