require "../../spec_helper"

describe Chiasmus::Graph::FactsSnapshot do
  it "round-trips snapshot metadata lines" do
    metadata = Chiasmus::Graph::FactsSnapshot::Metadata.new(
      cache_dir: "/tmp/chiasmus-cache",
      repo_key: "repo-key",
      snapshot: "facts-seed"
    )

    line = Chiasmus::Graph::FactsSnapshot.metadata_line(metadata)
    parsed = Chiasmus::Graph::FactsSnapshot.parse_metadata_line?(line)

    parsed.should eq(metadata)
  end

  it "returns nil for malformed snapshot metadata lines" do
    Chiasmus::Graph::FactsSnapshot.parse_metadata_line?("% graph_snapshot not-json").should be_nil
    Chiasmus::Graph::FactsSnapshot.parse_metadata_line?("% graph_snapshot {\"cache_dir\":\"/tmp\"}").should be_nil
    Chiasmus::Graph::FactsSnapshot.parse_metadata_line?("defines('a', 'b', function, 1, 1).").should be_nil
  end

  it "returns nil when the referenced snapshot cannot be loaded" do
    dir = File.join(Dir.tempdir, "chiasmus-facts-snapshot-missing-#{Random::Secure.hex(8)}")
    facts_path = File.join(dir, "facts.pl")
    Dir.mkdir_p(dir)

    begin
      metadata = Chiasmus::Graph::FactsSnapshot::Metadata.new(
        cache_dir: File.join(dir, "cache"),
        repo_key: "missing-repo",
        snapshot: "missing"
      )
      File.write(facts_path, <<-PL)
% chiasmus-facts language=typescript dir=#{dir} files=1
#{Chiasmus::Graph::FactsSnapshot.metadata_line(metadata)}
defines('src/app.ts', 'main', function, 1, 1).
PL

      Chiasmus::Graph::FactsSnapshot.load_graph_from_facts(facts_path).should be_nil
    ensure
      Chiasmus::Graph::GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(dir)
    end
  end
end
