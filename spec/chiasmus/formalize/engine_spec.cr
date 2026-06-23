require "../../spec_helper"
require "../../support/formalize_scripted_agent"
require "file_utils"

private def z3_available? : Bool
  Process.run("which", ["z3"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
rescue
  false
end

private def swipl_available? : Bool
  Process.run("which", ["swipl"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
rescue
  false
end

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
        raise "expected non-nil result" if result.nil?

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
        raise "expected non-nil result" if result.nil?

        result.template.solver.should eq(Chiasmus::Solvers::SolverType::Prolog)
        {"rule-inference", "permission-derivation"}.should contain(result.template.name)
      end
    end

    it "selects graph reachability for data flow problems" do
      with_formalize_engine do |engine, _library|
        formalized = engine.formalize(
          "Can user input reach the database through any chain of function calls?"
        )
        raise "expected non-nil formalized" if formalized.nil?
        formalized.template.name.should eq("graph-reachability")
      end
    end

    it "selects constraint satisfaction for dependency problems" do
      with_formalize_engine do |engine, _library|
        formalized = engine.formalize(
          "Find compatible versions for these npm packages given their peer dependency constraints"
        )
        raise "expected non-nil formalized" if formalized.nil?
        formalized.template.name.should eq("constraint-satisfaction")
      end
    end

    it "includes normalization guidance in instructions" do
      with_formalize_engine do |engine, _library|
        result = engine.formalize(
          "Check if our Kubernetes RBAC roles have conflicting permissions"
        )
        raise "expected non-nil result" if result.nil?

        result.instructions.should contain("Kubernetes")
      end
    end

    it "returns a fallback template when search finds nothing" do
      with_formalize_engine do |engine, _library|
        result = engine.formalize("zzz xyxxy zzzz blarg no match whatsoever")
        raise "expected non-nil result" if result.nil?
        result.template.should_not be_nil
        result.instructions.should_not be_empty
      end
    end

    it "uses embedding-based selection when an embedding adapter is provided" do
      dir = File.join(Dir.tempdir, "chiasmus-formalize-engine-embed-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(dir)
      library = Chiasmus::Skills::Library.create(dir)

      # Embedding: return matching vector for constraint-satisfaction text and
      # the problem, orthogonal vectors for everything else.
      embedding = ->(texts : Array(String)) : Array(Array(Float64)) do
        texts.map do |text|
          if text.includes?("compatible") || text.includes?("constraint-satisfaction")
            [1.0, 0.0, 0.0]
          else
            [0.0, 1.0, 0.0]
          end
        end
      end

      engine = Chiasmus::Formalize::Engine(Chiasmus::LLM::MockCompletionModel).new(
        library,
        Chiasmus::LLM::MockAdapter.create_agent,
        embedding: embedding,
      )

      begin
        result = engine.formalize(
          "Find compatible versions for these npm packages given their peer dependency constraints"
        )
        raise "expected non-nil result" if result.nil?
        result.template.name.should eq("constraint-satisfaction")
      ensure
        library.close
        FileUtils.rm_rf(dir)
      end
    end

    it "falls back to BM25 when embedding adapter fails" do
      dir = File.join(Dir.tempdir, "chiasmus-formalize-engine-embed-fail-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(dir)
      library = Chiasmus::Skills::Library.create(dir)

      # Embedding that always raises
      failing_embedding = ->(_texts : Array(String)) : Array(Array(Float64)) do
        raise "embedding service unavailable"
      end

      engine = Chiasmus::Formalize::Engine(Chiasmus::LLM::MockCompletionModel).new(
        library,
        Chiasmus::LLM::MockAdapter.create_agent,
        embedding: failing_embedding,
      )

      begin
        result = engine.formalize(
          "Check if our RBAC rules can ever allow and deny the same user accessing the same resource"
        )
        raise "expected non-nil result" if result.nil?
        result.template.name.should eq("policy-contradiction")
      ensure
        library.close
        FileUtils.rm_rf(dir)
      end
    end
  end

  describe "#formalize_async" do
    it "returns through an async channel boundary" do
      with_formalize_engine do |engine, _library|
        entered = Channel(Bool).new(1)
        release = Channel(Bool).new(1)

        Chiasmus::Formalize::Engine(Chiasmus::LLM::MockCompletionModel).set_before_formalize_async_result_send_hook_for_test do
          entered.send(true)
          release.receive
        end

        result_chan = engine.formalize_async(
          "Check if our RBAC rules can ever allow and deny the same user accessing the same resource"
        )

        Chiasmus::Utils::Timeout.with_timeout_async(250, entered).should eq(true)

        select
        when result_chan.receive?
          fail("expected formalize_async to wait on async result boundary")
        else
        end

        release.send(true)
        result = Chiasmus::Utils::Timeout.with_timeout_async(500, result_chan)
        result.should_not be_nil
        result.not_nil!.error.should be_nil
        result.not_nil!.value.try(&.template.name).should eq("policy-contradiction")
      ensure
        Chiasmus::Formalize::Engine(Chiasmus::LLM::MockCompletionModel).clear_before_formalize_async_result_send_hook_for_test
      end
    end
  end

  describe "#solve" do
    before_all do
      unless z3_available? && swipl_available?
        pending "z3 or swipl not installed"
      end
    end

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

  describe "#solve_async" do
    before_all do
      unless z3_available? && swipl_available?
        pending "z3 or swipl not installed"
      end
    end

    it "returns through an async channel boundary" do
      responses = [%( (declare-const x Int) (assert (> x 5)) ).strip]

      with_scripted_formalize_engine(responses) do |engine, _library, _prompts|
        entered = Channel(Bool).new(1)
        release = Channel(Bool).new(1)

        Chiasmus::Formalize::Engine(FormalizeSpecCompletionModel).set_before_solve_async_result_send_hook_for_test do
          entered.send(true)
          release.receive
        end

        result_chan = engine.solve_async("Find an integer greater than 5")

        Chiasmus::Utils::Timeout.with_timeout_async(250, entered).should eq(true)

        select
        when result_chan.receive?
          fail("expected solve_async to wait on async result boundary")
        else
        end

        release.send(true)
        result = Chiasmus::Utils::Timeout.with_timeout_async(500, result_chan)
        result.should_not be_nil
        result.not_nil!.error.should be_nil
        result.not_nil!.value.try(&.converged).should be_true
      ensure
        Chiasmus::Formalize::Engine(FormalizeSpecCompletionModel).clear_before_solve_async_result_send_hook_for_test
      end
    end
  end
end
