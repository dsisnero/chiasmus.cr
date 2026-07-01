require "../../spec_helper"
require "../../../src/chiasmus/parity/naming"

describe Chiasmus::Parity::Naming do
  it "normalizes keys across casing and escaped suffix variants" do
    Chiasmus::Parity::Naming.normalized_key("buildGapCheck").should eq("build_gap_check")
    Chiasmus::Parity::Naming.normalized_key("build_gap_check").should eq("build_gap_check")
    Chiasmus::Parity::Naming.normalized_key("selectEscaped").should eq("select")
    Chiasmus::Parity::Naming.normalized_key("select_escaped").should eq("select")
    Chiasmus::Parity::Naming.normalized_key("A+B").should eq("a_plus_b")
  end

  it "extracts normalized owners from qualified names" do
    Chiasmus::Parity::Naming.normalized_owner("FormalizationEngine.constructor").should eq("formalization_engine")
    Chiasmus::Parity::Naming.normalized_owner("Chiasmus::Formalize::lint_spec").should eq("chiasmus.formalize")
  end
end
