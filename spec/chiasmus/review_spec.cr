require "../spec_helper"
require "../../src/chiasmus/review"

describe Chiasmus::Review do
  files = ["/abs/src/handler.ts", "/abs/src/db.ts"]

  describe ".build_plan" do
    it "returns a plan with files echoed back" do
      plan = Chiasmus::Review.build_plan(files)
      plan.files.should eq files
      plan.focus.should eq "all"
    end

    it "defaults focus to 'all' when omitted" do
      plan = Chiasmus::Review.build_plan(files)
      plan.focus.should eq "all"
    end

    it "returns phases as a non-empty array" do
      plan = Chiasmus::Review.build_plan(files)
      plan.phases.should_not be_empty
      plan.phases.each do |phase|
        phase.phase.should_not be_empty
        phase.goal.should_not be_empty
      end
    end

    it "phase actions reference real chiasmus tools" do
      valid_tools = Set{"chiasmus_graph", "chiasmus_formalize", "chiasmus_verify", "chiasmus_skills", "chiasmus_lint"}
      plan = Chiasmus::Review.build_plan(files)
      plan.phases.each do |phase|
        phase.actions.each do |action|
          valid_tools.includes?(action.tool).should be_true
          action.interpret.should_not be_empty
        end
      end
    end

    it "'all' focus includes structural, architecture, security, correctness phases" do
      plan = Chiasmus::Review.build_plan(files, "all")
      phase_names = plan.phases.map(&.phase.downcase)
      (phase_names.any? { |n| n.includes?("structural") || n.includes?("overview") }).should be_true
      (phase_names.any? { |n| n.includes?("architecture") || n.includes?("dead") || n.includes?("layer") }).should be_true
      (phase_names.any? { |n| n.includes?("security") || n.includes?("taint") || n.includes?("data flow") }).should be_true
      (phase_names.any? { |n| n.includes?("correctness") || n.includes?("invariant") || n.includes?("bug") }).should be_true
    end

    it "'quick' focus is a strict subset of 'all' (fewer phases)" do
      all = Chiasmus::Review.build_plan(files, "all")
      quick = Chiasmus::Review.build_plan(files, "quick")
      quick.phases.size.should be < all.phases.size
      quick.phases.should_not be_empty
    end

    it "'security' focus includes taint-propagation via chiasmus_formalize" do
      plan = Chiasmus::Review.build_plan(files, "security")
      has_formalize = plan.phases.any? { |p| p.actions.any? { |a| a.tool == "chiasmus_formalize" } }
      has_formalize.should be_true
      mentions_taint = plan.phases.any? { |p| p.actions.any? { |a| a.interpret.downcase.includes?("taint") } }
      mentions_taint.should be_true
    end

    it "'architecture' focus includes dead-code, cycles, and layer-violation analyses" do
      plan = Chiasmus::Review.build_plan(files, "architecture")
      analyses = Set(String).new
      plan.phases.each do |phase|
        phase.actions.each do |action|
          if action.tool == "chiasmus_graph"
            a = action.args["analysis"]?.try(&.as_s?)
            analyses << a if a
          end
        end
      end
      analyses.includes?("dead-code").should be_true
      analyses.includes?("cycles").should be_true
      analyses.includes?("layer-violation").should be_true
    end

    it "'correctness' focus suggests invariant-check or boundary-condition templates" do
      plan = Chiasmus::Review.build_plan(files, "correctness")
      suggested = plan.suggested_templates.map(&.template)
      has_suggested = suggested.includes?("invariant-check") || suggested.includes?("boundary-condition") || suggested.includes?("state-machine-deadlock")
      has_suggested.should be_true
    end

    it "graph actions pass through the files array" do
      plan = Chiasmus::Review.build_plan(files)
      plan.phases.each do |phase|
        phase.actions.each do |action|
          if action.tool == "chiasmus_graph"
            action.args["files"]?.try(&.as_a.try(&.map(&.as_s))).should eq files
          end
        end
      end
    end

    it "includes entry_points in graph actions when provided" do
      plan = Chiasmus::Review.build_plan(files, "all", ["handleRequest", "main"])
      dead_code_action = plan.phases.flat_map(&.actions).find { |a| a.tool == "chiasmus_graph" && a.args["analysis"]?.try(&.as_s?) == "dead-code" }
      dead_code_action.should_not be_nil
      dead_code_action.not_nil!.args["entry_points"]?.try(&.as_a.try(&.map(&.as_s))).should eq ["handleRequest", "main"]
    end

    it "includes a reporting section describing severity format" do
      plan = Chiasmus::Review.build_plan(files)
      plan.reporting.format.should_not be_empty
      plan.reporting.severity_levels.should_not be_empty
    end

    it "includes a suggestedTemplates section listing named templates with workflow hints" do
      plan = Chiasmus::Review.build_plan(files)
      plan.suggested_templates.should_not be_empty
      plan.suggested_templates.each do |t|
        t.template.should_not be_empty
        t.when.should_not be_empty
        t.workflow.should_not be_empty
      end
    end

    it "rejects empty files array" do
      expect_raises(ArgumentError, /files/i) do
        Chiasmus::Review.build_plan([] of String)
      end
    end

    it "rejects unknown focus value" do
      expect_raises(ArgumentError, /focus/i) do
        Chiasmus::Review.build_plan(files, "nonsense")
      end
    end
  end

  describe "delta_against PR review mode" do
    it "inserts a delta phase as phase 0 when delta_against is supplied" do
      plan = Chiasmus::Review.build_plan(files, delta_against: "main")
      phases = plan.phases
      phases.should_not be_empty
      phases[0].phase.should contain("0.")
      phases[0].phase.should match(/delta/i)
    end

    it "delta phase is absent when delta_against is omitted" do
      plan = Chiasmus::Review.build_plan(files)
      phases = plan.phases
      phases.none? { |p| p.phase.includes?("delta") || p.phase.includes?("0.") }.should be_true
    end

    it "reporting section mentions PR scope when delta_against is set" do
      plan = Chiasmus::Review.build_plan(files, delta_against: "main")
      plan.reporting.instructions.should match(/PR review|delta|change/i)
    end

    it "delta phase still fires under focus='quick'" do
      plan = Chiasmus::Review.build_plan(files, "quick", delta_against: "main")
      phases = plan.phases
      phases.any? { |p| p.phase =~ /delta/i }.should be_true
    end
  end
end
