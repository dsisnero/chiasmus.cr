require "../../spec_helper"
require "../../../src/chiasmus/graph/names"

describe Chiasmus::Graph::Names do
  it "extracts owner names from qualified names" do
    Chiasmus::Graph::Names.owner_name("Demo.Config.load").should eq("Demo.Config")
    Chiasmus::Graph::Names.owner_name("main").should be_nil
  end

  it "extracts simple names from qualified names" do
    Chiasmus::Graph::Names.simple_name("Demo.Config.load").should eq("load")
    Chiasmus::Graph::Names.simple_name("main").should eq("main")
  end

  it "merges containment names without duplicating overlapping qualifiers" do
    Chiasmus::Graph::Names.merge_containment_names("Demo", "Config").should eq("Demo.Config")
    Chiasmus::Graph::Names.merge_containment_names("Demo.Config", "Config.load").should eq("Demo.Config.load")
    Chiasmus::Graph::Names.merge_containment_names("Demo", "Demo.Service.helper").should eq("Demo.Service.helper")
    Chiasmus::Graph::Names.merge_containment_names("Demo", "Demo").should eq("Demo")
  end
end
