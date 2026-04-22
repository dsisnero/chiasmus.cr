require "../../spec_helper"

describe Chiasmus::Skills do
  describe ".get_related_templates" do
    it "returns related templates for policy-contradiction" do
      names = Chiasmus::Skills.get_related_templates("policy-contradiction").map(&.name)
      names.should contain("policy-reachability")
      names.should contain("permission-derivation")
    end

    it "returns related templates for schema-consistency" do
      names = Chiasmus::Skills.get_related_templates("schema-consistency").map(&.name)
      names.should contain("config-equivalence")
      names.should contain("constraint-satisfaction")
    end

    it "returns an empty array for unknown templates" do
      Chiasmus::Skills.get_related_templates("nonexistent").should eq([] of Chiasmus::Skills::RelatedTemplate)
    end

    it "gives every starter template at least one related template" do
      Chiasmus::Skills::STARTER_TEMPLATES.each do |template|
        Chiasmus::Skills.get_related_templates(template.name).size.should be > 0, "#{template.name} should have related templates"
      end
    end

    it "uses descriptive non-empty relationship reasons" do
      Chiasmus::Skills::STARTER_TEMPLATES.each do |template|
        Chiasmus::Skills.get_related_templates(template.name).each do |related|
          related.reason.size.should be > 10, "#{template.name} -> #{related.name} reason is too short"
        end
      end
    end
  end
end
