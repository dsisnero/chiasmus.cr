require "../../spec_helper"

describe Chiasmus::Skills do
  describe ".get_related_templates" do
    it "ships the full upstream starter corpus" do
      Chiasmus::Skills::STARTER_TEMPLATES.map(&.name).sort.should eq([
        "policy-contradiction", "policy-reachability", "config-equivalence",
        "constraint-satisfaction", "schema-consistency", "graph-reachability",
        "rule-inference", "permission-derivation", "invariant-check",
        "state-machine-deadlock", "boundary-condition", "association-rule-check",
        "collective-classification", "taint-propagation",
      ].sort)
    end

    it "includes relationships for the code-review starters" do
      Chiasmus::Skills.get_related_templates("invariant-check").map(&.name).should eq([
        "boundary-condition", "state-machine-deadlock",
      ])
    end

    it "returns related templates for policy-contradiction" do
      related = Chiasmus::Skills.get_related_templates("policy-contradiction")
      related.should_not be_empty
      related.map(&.name).should contain("policy-reachability")
      related.map(&.name).should contain("permission-derivation")
    end

    it "returns related templates for schema-consistency" do
      related = Chiasmus::Skills.get_related_templates("schema-consistency")
      related.should_not be_empty
      names = related.map(&.name)
      names.should contain("config-equivalence")
      names.should contain("constraint-satisfaction")
    end

    it "returns empty array for unknown template" do
      Chiasmus::Skills.get_related_templates("nonexistent").should be_empty
    end

    it "all starter templates have at least one related template" do
      Chiasmus::Skills::STARTER_TEMPLATES.each do |template|
        related = Chiasmus::Skills.get_related_templates(template.name)
        related.should_not be_empty, "Template #{template.name} has no related templates"
      end
    end

    it "all reason strings are non-empty and descriptive" do
      Chiasmus::Skills::STARTER_TEMPLATES.each do |template|
        related = Chiasmus::Skills.get_related_templates(template.name)
        related.each do |rel|
          rel.reason.should_not be_empty
          rel.reason.size.should be > 5
        end
      end
    end
  end
end
