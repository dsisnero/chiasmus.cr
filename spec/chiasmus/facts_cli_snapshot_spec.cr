require "../spec_helper"

describe Chiasmus::FactsCLI do
  it "emits graph snapshot metadata and persists the extracted graph when cache is enabled" do
    dir = File.join(Dir.tempdir, "chiasmus-facts-cli-snapshot-#{Random::Secure.hex(8)}")
    cache_dir = File.join(dir, "cache")
    source_dir = File.join(dir, "src")
    Dir.mkdir_p(source_dir)
    File.write(File.join(source_dir, "sample.cr"), <<-CR)
      module Demo
        def self.run
          helper
        end

        def self.helper
        end
      end
    CR

    output = IO::Memory.new
    error = IO::Memory.new

    begin
      exit_code = Chiasmus::FactsCLI.run(
        ["--language", "crystal", "--dir", source_dir, "--cache-dir", cache_dir],
        output: output,
        error: error
      )

      exit_code.should eq(0), error.to_s
      snapshot_line = output.to_s.each_line.find { |line| line.starts_with?("% graph_snapshot ") }
      snapshot_line.should_not be_nil
      metadata = Chiasmus::Graph::FactsSnapshot.parse_metadata_line?(snapshot_line || "")
      metadata.should_not be_nil
      loaded = Chiasmus::Graph::GraphCache.load_snapshot(
        metadata.not_nil!.snapshot,
        metadata.not_nil!.cache_dir,
        repo_key: metadata.not_nil!.repo_key
      )
      loaded.should_not be_nil
      loaded.not_nil!.defines.map(&.name).should contain("run")
    ensure
      Chiasmus::Graph::GraphCache.flush_async_writes
      Chiasmus::Graph::GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(dir)
    end
  end
end
