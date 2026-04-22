require "../../spec_helper"
require "../../support/formalize_scripted_agent"
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

def with_scripted_formalize_engine(responses : Array(String), &)
  dir = File.join(Dir.tempdir, "chiasmus-formalize-engine-scripted-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(dir)
  library = Chiasmus::Skills::Library.create(dir)
  prompts = [] of String
  agent = FormalizeSpecClient.new(responses, prompts).agent("mock").build
  engine = Chiasmus::Formalize::Engine(FormalizeSpecCompletionModel).new(library, agent)

  begin
    yield engine, library, prompts
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

  describe "#solve" do
    it "solves a z3 policy contradiction problem end-to-end" do
      responses = [<<-TEXT.strip]
      (declare-const x Int)
      (assert (> x 5))
      TEXT

      with_scripted_formalize_engine(responses) do |engine, _library, _prompts|
        result = engine.solve("Can an editor ever be both allowed and denied write access?")

        result.converged.should be_true
        result.result.status.should eq("sat")
        result.template_used.should_not be_nil
      end
    end

    it "solves a prolog reachability problem end-to-end" do
      responses = [<<-TEXT.strip]
      edge(user_input, api_handler).
      edge(api_handler, validator).
      edge(validator, database).
      edge(api_handler, logger).

      reaches(A, B) :- edge(A, B).
      reaches(A, B) :- edge(A, Mid), reaches(Mid, B).

      ?- reaches(user_input, database).
      TEXT

      with_scripted_formalize_engine(responses) do |engine, _library, _prompts|
        result = engine.solve("Can user input data reach the database through any chain of calls in this directed graph?")

        result.converged.should be_true
        result.result.status.should eq("success")
        result.answers.size.should be >= 1
      end
    end

    it "uses the correction loop when the initial formalization has errors" do
      responses = [
        %( (declare-const x Int) (assert (> x "bad")) ).strip,
        %( (declare-const x Int) (assert (> x 5)) ).strip,
      ]

      with_scripted_formalize_engine(responses) do |engine, _library, _prompts|
        result = engine.solve("Find an integer greater than 5")

        result.converged.should be_true
        result.rounds.should be > 1
        result.result.status.should eq("sat")
      end
    end

    it "returns failure with diagnostics when the correction loop exhausts" do
      responses = Array.new(4, %( (declare-const x Int) (assert (= x y)) ).strip)

      with_scripted_formalize_engine(responses) do |engine, _library, _prompts|
        result = engine.solve("Find an integer greater than 5", 3)

        result.converged.should be_false
        result.history.should_not be_empty
        result.result.status.should eq("error")
      end
    end

    it "uses enriched feedback in correction prompts" do
      responses = [
        %( (declare-const x Int) (assert (> x "broken")) ).strip,
        %( (declare-const x Int) (assert (> x "still_broken")) ).strip,
        %( (declare-const x Int) (assert (> x 5)) ).strip,
      ]

      with_scripted_formalize_engine(responses) do |engine, _library, prompts|
        engine.solve("Find an integer greater than 5")

        feedback_prompts = prompts.select { |prompt| prompt.includes?("FEEDBACK:") || prompt.includes?("Solver error") }
        feedback_prompts.should_not be_empty
      end
    end

    it "records template use in the skill library" do
      responses = [<<-TEXT.strip]
      (declare-const x Int)
      (declare-const y Int)
      (assert (= (+ x y) 10))
      (assert (> x 0))
      (assert (> y 0))
      TEXT

      with_scripted_formalize_engine(responses) do |engine, library, _prompts|
        engine.solve("Find two positive numbers that add to 10")

        library.list.any? { |item| item.metadata.reuse_count > 0 }.should be_true
      end
    end
  end
end
