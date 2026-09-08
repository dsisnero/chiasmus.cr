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

describe "tree-sitter CLI entrypoints" do
  it "disables tree-sitter-manager argument interception before requiring application code" do
    %w[src/chiasmus_discover.cr src/chiasmus_facts.cr].each do |path|
      source = File.read(path)
      guard_offset = source.index(%(ENV["TREE_SITTER_MANAGER_NO_AUTO_RUN"] = "1"))
      require_offset = source.index(/^require /m)

      guard_position = guard_offset || fail("missing tree-sitter-manager guard in #{path}")
      require_position = require_offset || fail("missing application require in #{path}")
      guard_position.should be < require_position
    end
  end

  it "installs the Chiasmus grammar baseline through the manager-backed batch command" do
    source = File.read("scripts/setup_grammars_new.cr")

    source.should contain("\"scheme\"")
    source.should contain("\"commonlisp\"")
    source.should contain("run_command(\"bin/chiasmus-grammar\", [\"batch\", DEFAULT_LANGUAGES.join(\",\")])")
    source.should_not contain("[\"compile\", language]")
  end
end
