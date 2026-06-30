require "../spec_helper"
require "yaml"

describe "shard.yml CLI targets" do
  it "declares the parity workflow binaries" do
    shard = YAML.parse(File.read(File.expand_path("../../shard.yml", __DIR__)))
    targets = shard["targets"].as_h

    targets.keys.map(&.to_s).should contain("chiasmus-discover")
    targets.keys.map(&.to_s).should contain("chiasmus-facts")
    targets.keys.map(&.to_s).should contain("chiasmus-plan")
    targets.keys.map(&.to_s).should contain("chiasmus-parity")
    targets.keys.map(&.to_s).should contain("chiasmus-complete")

    targets["chiasmus-facts"].["main"].as_s.should eq("src/chiasmus_facts.cr")
  end
end
