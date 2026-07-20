require "../../spec_helper"
require "file_utils"

def with_craft_library(&)
  dir = File.join(Dir.tempdir, "chiasmus-craft-spec-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(dir)
  library = Chiasmus::Skills::Library.create(dir)
  begin
    yield library, dir
  ensure
    library.close
    FileUtils.rm_rf(dir)
  end
end

private def swipl_available_for_craft_spec? : Bool
  Process.run("which", ["swipl"], output: Process::Redirect::Close, error: Process::Redirect::Close).success?
rescue
  false
end

def valid_craft_input(**overrides)
  Chiasmus::Skills::CraftInput.new(**{
    name:      "test-template",
    domain:    "validation",
    solver:    "z3",
    signature: "Check if two validation rule sets are consistent",
    skeleton:  "{{SLOT:declarations}}\n(assert (not (= {{SLOT:rule_a}} {{SLOT:rule_b}})))",
    slots:     [
      Chiasmus::Skills::SlotDef.new(
        name: "declarations",
        description: "Variable declarations",
        format: "(declare-const x Int)"
      ),
      Chiasmus::Skills::SlotDef.new(
        name: "rule_a",
        description: "First rule expression",
        format: "(> x 0)"
      ),
      Chiasmus::Skills::SlotDef.new(
        name: "rule_b",
        description: "Second rule expression",
        format: "(> x 0)"
      ),
    ],
    normalizations: [
      Chiasmus::Skills::Normalization.new(
        source: "JSON Schema",
        transform: "Map each property constraint to an SMT expression"
      ),
    ],
    tips:    nil,
    example: nil,
    test:    false,
  }.merge(overrides))
end

describe Chiasmus::Skills do
  describe ".validate_template" do
    it "accepts a valid template" do
      with_craft_library do |library, _dir|
        errors = Chiasmus::Skills.validate_template(valid_craft_input, library)
        errors.should be_empty
      end
    end

    it "requires non-empty string fields" do
      with_craft_library do |library, _dir|
        errors = Chiasmus::Skills.validate_template(valid_craft_input(name: ""), library)
        errors.any?(&.includes?("name")).should be_true
      end
    end

    it "rejects invalid solver values" do
      with_craft_library do |library, _dir|
        errors = Chiasmus::Skills.validate_template(valid_craft_input(solver: "invalid"), library)
        errors.any?(&.includes?("solver")).should be_true
      end
    end

    it "rejects skeleton slots that are not defined" do
      with_craft_library do |library, _dir|
        input = valid_craft_input(
          skeleton: "{{SLOT:declarations}}\n{{SLOT:missing_slot}}",
          slots: [
            Chiasmus::Skills::SlotDef.new(name: "declarations", description: "Decls", format: "..."),
          ]
        )

        errors = Chiasmus::Skills.validate_template(input, library)
        errors.any? { |error| error.includes?("missing_slot") && error.includes?("not defined") }.should be_true
      end
    end

    it "rejects defined slots that are not referenced" do
      with_craft_library do |library, _dir|
        input = valid_craft_input(
          skeleton: "{{SLOT:declarations}}",
          slots: [
            Chiasmus::Skills::SlotDef.new(name: "declarations", description: "Decls", format: "..."),
            Chiasmus::Skills::SlotDef.new(name: "extra_slot", description: "Extra", format: "..."),
          ]
        )

        errors = Chiasmus::Skills.validate_template(input, library)
        errors.any? { |error| error.includes?("extra_slot") && error.includes?("not referenced") }.should be_true
      end
    end

    it "rejects duplicate template names" do
      with_craft_library do |library, _dir|
        Chiasmus::Skills.craft_template(valid_craft_input, library)

        errors = Chiasmus::Skills.validate_template(valid_craft_input, library)
        errors.any?(&.includes?("already exists")).should be_true
      end
    end

    it "requires non-empty slots" do
      with_craft_library do |library, _dir|
        errors = Chiasmus::Skills.validate_template(valid_craft_input(slots: [] of Chiasmus::Skills::SlotDef), library)
        errors.any? { |error| error.includes?("slots") && error.includes?("non-empty") }.should be_true
      end
    end

    it "requires non-empty normalizations" do
      with_craft_library do |library, _dir|
        errors = Chiasmus::Skills.validate_template(valid_craft_input(normalizations: [] of Chiasmus::Skills::Normalization), library)
        errors.any? { |error| error.includes?("normalizations") && error.includes?("non-empty") }.should be_true
      end
    end
  end

  describe ".craft_template" do
    it "adds a valid template and makes it searchable" do
      with_craft_library do |library, _dir|
        result = Chiasmus::Skills.craft_template(valid_craft_input, library)

        result.created.should be_true
        result.template.should eq("test-template")
        library.search("validation rule sets consistent").map(&.template.name).should contain("test-template")
      end
    end

    it "tests valid z3 examples through the solver" do
      with_craft_library do |library, _dir|
        result = Chiasmus::Skills.craft_template(valid_craft_input(
          example: "(declare-const x Int)\n(assert (> x 0))\n(assert (< x 10))",
          test: true
        ), library)

        result.created.should be_true
        result.tested.should be_true
        result.test_result.should eq("sat")
      end
    end

    it "returns error for broken z3 examples while still creating the template" do
      with_craft_library do |library, _dir|
        result = Chiasmus::Skills.craft_template(valid_craft_input(
          example: "(declare-const x Int) (assert (> x \"bad\"))",
          test: true
        ), library)

        result.created.should be_true
        result.tested.should be_true
        result.test_result.should eq("error")
      end
    end

    it "tests valid prolog examples through the solver" do
      with_craft_library do |library, _dir|
        result = Chiasmus::Skills.craft_template(valid_craft_input(
          solver: "prolog",
          skeleton: "{{SLOT:facts}}\n{{SLOT:rules}}",
          slots: [
            Chiasmus::Skills::SlotDef.new(name: "facts", description: "Facts", format: "parent(tom, bob)."),
            Chiasmus::Skills::SlotDef.new(name: "rules", description: "Rules", format: "ancestor(X,Y) :- parent(X,Y)."),
          ],
          example: "parent(tom, bob).\nparent(bob, ann).\n?- parent(tom, X).",
          test: true
        ), library)

        result.created.should be_true
        result.tested.should be_true
        result.test_result.should eq("success")
      end
    end

    it "emits tracing breadcrumbs for the prolog template test path" do
      next pending("swipl not installed") unless swipl_available_for_craft_spec?

      mock = Tracing::MockSubscriber.new

      with_craft_library do |library, _dir|
        Tracing::Dispatch.with_default(Tracing::Dispatch.new(mock)) do
          result = Chiasmus::Skills.craft_template(valid_craft_input(
            name: "traced-template",
            solver: "prolog",
            skeleton: "{{SLOT:facts}}\n{{SLOT:rules}}",
            slots: [
              Chiasmus::Skills::SlotDef.new(name: "facts", description: "Facts", format: "parent(tom, bob)."),
              Chiasmus::Skills::SlotDef.new(name: "rules", description: "Rules", format: "ancestor(X,Y) :- parent(X,Y)."),
            ],
            example: "parent(tom, bob).\nparent(bob, ann).\n?- parent(tom, X).",
            test: true
          ), library)

          result.created.should be_true
          result.test_result.should eq("success")
        end
      end

      span_names = mock.spans.map { |attrs, _| attrs.metadata.name }
      event_names = mock.events.map(&.metadata.name)
      span_names.should contain("chiasmus.skills.craft_template")
      event_names.should contain("chiasmus.skills.template_test.start")
      event_names.should contain("chiasmus.prolog.solve.enqueue")
      event_names.should contain("chiasmus.prolog.solve.complete")
      event_names.should contain("chiasmus.skills.template_test.dispose")
    end

    it "returns validation errors without creating the template" do
      with_craft_library do |library, _dir|
        result = Chiasmus::Skills.craft_template(valid_craft_input(solver: "invalid"), library)

        result.created.should be_false
        result.errors.should_not be_nil
        if errors = result.errors
          errors.should_not be_empty
        end
      end
    end
  end
end
