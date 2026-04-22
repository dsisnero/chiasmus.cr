require "../../spec_helper"
require "file_utils"

def with_library(&)
  dir = File.join(Dir.tempdir, "chiasmus-learn-spec-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(dir)
  library = Chiasmus::Skills::Library.create(dir)
  begin
    yield library
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe Chiasmus::Skills::Learner do
  describe "#extract_template" do
    it "extracts a z3 template from a verified solution" do
      with_library do |library|
        extractor = ->(solver : Chiasmus::Solvers::SolverType, _spec : String, _problem : String) do
          solver.should eq(Chiasmus::Solvers::SolverType::Z3)
          {
            "name"      => "port-range-overlap",
            "domain"    => "configuration",
            "signature" => "Check if two port ranges overlap",
            "slots"     => [
              {"name" => "range_declarations", "description" => "Port range variables", "format" => "(declare-const port Int)"},
              {"name" => "range_a_constraints", "description" => "First port range bounds", "format" => "(assert (and (>= port 80) (<= port 443)))"},
              {"name" => "range_b_constraints", "description" => "Second port range bounds", "format" => "(assert (and (>= port 8080) (<= port 8443)))"},
            ],
            "normalizations" => [
              {"source" => "firewall rules", "transform" => "Extract port ranges from rule definitions"},
            ],
            "skeleton" => "(declare-const port Int)\n{{SLOT:range_a_constraints}}\n{{SLOT:range_b_constraints}}",
          }.to_json
        end
        learner = Chiasmus::Skills::Learner.new(library, extractor)

        result = learner.extract_template(
          Chiasmus::Solvers::SolverType::Z3,
          "(declare-const port Int)\n(assert (and (>= port 80) (<= port 443)))\n(assert (and (>= port 8080) (<= port 8443)))",
          "Check if ports 80-443 and 8080-8443 overlap"
        )

        result.should_not be_nil
        result.not_nil!.name.should eq("port-range-overlap")
        result.not_nil!.solver.should eq(Chiasmus::Solvers::SolverType::Z3)

        found = library.get("port-range-overlap")
        found.should_not be_nil
        found.not_nil!.metadata.promoted.should be_false
      end
    end

    it "extracts a prolog template from a verified solution" do
      with_library do |library|
        extractor = ->(_solver : Chiasmus::Solvers::SolverType, _spec : String, _problem : String) do
          {
            "name"      => "dependency-ordering",
            "domain"    => "analysis",
            "signature" => "Determine a valid execution order respecting dependencies",
            "slots"     => [
              {"name" => "dependencies", "description" => "Dependency edges", "format" => "depends(build, compile)."},
            ],
            "normalizations" => [
              {"source" => "Makefile", "transform" => "Extract target dependencies as depends/2 facts"},
            ],
            "skeleton" => "{{SLOT:dependencies}}\ncan_run_before(A, B) :- depends(B, A).\ncan_run_before(A, B) :- depends(B, Mid), can_run_before(A, Mid).",
          }.to_json
        end
        learner = Chiasmus::Skills::Learner.new(library, extractor)

        result = learner.extract_template(
          Chiasmus::Solvers::SolverType::Prolog,
          "depends(build, compile).\ndepends(test, build).\ncan_run_before(A, B) :- depends(B, A).\ncan_run_before(A, B) :- depends(B, Mid), can_run_before(A, Mid).",
          "Determine build order for compilation pipeline"
        )

        result.should_not be_nil
        result.not_nil!.solver.should eq(Chiasmus::Solvers::SolverType::Prolog)
      end
    end

    it "returns nil when extractor produces invalid json" do
      with_library do |library|
        learner = Chiasmus::Skills::Learner.new(library, ->(_solver : Chiasmus::Solvers::SolverType, _spec : String, _problem : String) { "this is not valid json at all" })

        learner.extract_template(
          Chiasmus::Solvers::SolverType::Z3,
          "(declare-const x Int) (assert (> x 5))",
          "Find a number greater than 5"
        ).should be_nil
      end
    end

    it "rejects templates with missing required fields" do
      with_library do |library|
        learner = Chiasmus::Skills::Learner.new(library, ->(_solver : Chiasmus::Solvers::SolverType, _spec : String, _problem : String) { {"name" => "incomplete"}.to_json })

        learner.extract_template(
          Chiasmus::Solvers::SolverType::Z3,
          "(declare-const x Int)",
          "test"
        ).should be_nil
      end
    end

    it "rejects near-duplicate templates" do
      with_library do |library|
        learner = Chiasmus::Skills::Learner.new(library, ->(_solver : Chiasmus::Solvers::SolverType, _spec : String, _problem : String) {
          {
            "name"           => "policy-conflict-check",
            "domain"         => "authorization",
            "signature"      => "Check if access control rules can ever produce contradictory allow/deny decisions for the same request",
            "slots"          => [{"name" => "rules", "description" => "Policy rules", "format" => "(assert ...)"}],
            "normalizations" => [{"source" => "IAM", "transform" => "Map policies to assertions"}],
            "skeleton"       => "{{SLOT:rules}}",
          }.to_json
        })

        learner.extract_template(
          Chiasmus::Solvers::SolverType::Z3,
          "(declare-const x Bool)",
          "Check policy conflicts"
        ).should be_nil
      end
    end
  end

  describe "#check_promotions" do
    it "promotes a template after sufficient successful reuses" do
      with_library do |library|
        learner = Chiasmus::Skills::Learner.new(library, ->(_solver : Chiasmus::Solvers::SolverType, _spec : String, _problem : String) {
          {
            "name"           => "unique-test-template",
            "domain"         => "validation",
            "signature"      => "A completely unique template for testing promotion",
            "slots"          => [{"name" => "input", "description" => "test input", "format" => "test"}],
            "normalizations" => [{"source" => "test", "transform" => "test"}],
            "skeleton"       => "{{SLOT:input}}",
          }.to_json
        })

        learner.extract_template(Chiasmus::Solvers::SolverType::Z3, "(declare-const x Int)", "unique test")
        library.get_metadata("unique-test-template").not_nil!.promoted.should be_false

        3.times { library.record_use("unique-test-template", true) }
        learner.check_promotions

        library.get_metadata("unique-test-template").not_nil!.promoted.should be_true
      end
    end

    it "does not promote templates with low success rate" do
      with_library do |library|
        learner = Chiasmus::Skills::Learner.new(library, ->(_solver : Chiasmus::Solvers::SolverType, _spec : String, _problem : String) {
          {
            "name"           => "flaky-template",
            "domain"         => "validation",
            "signature"      => "A template that mostly fails for testing non-promotion",
            "slots"          => [{"name" => "input", "description" => "test", "format" => "test"}],
            "normalizations" => [{"source" => "test", "transform" => "test"}],
            "skeleton"       => "{{SLOT:input}}",
          }.to_json
        })

        learner.extract_template(Chiasmus::Solvers::SolverType::Z3, "(declare-const x Int)", "flaky test")
        library.record_use("flaky-template", true)
        library.record_use("flaky-template", false)
        library.record_use("flaky-template", false)
        learner.check_promotions

        library.get_metadata("flaky-template").not_nil!.promoted.should be_false
      end
    end
  end
end
