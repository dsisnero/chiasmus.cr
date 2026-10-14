require "../spec_helper"

describe Chiasmus::FactsCLI do
  it "keeps earlier facts snapshots readable after a source update" do
    dir = File.join(Dir.tempdir, "chiasmus-facts-snapshot-history-#{Random::Secure.hex(8)}")
    source_dir = File.join(dir, "src")
    cache_dir = File.join(dir, "cache")
    source_path = File.join(source_dir, "sample.cr")
    old_facts = File.join(dir, "old.pl")
    new_facts = File.join(dir, "new.pl")
    Dir.mkdir_p(source_dir)

    begin
      File.write(source_path, "def before_update\nend\n")
      old_output = IO::Memory.new
      Chiasmus::FactsCLI.run(["--language", "crystal", "--dir", source_dir, "--cache-dir", cache_dir], output: old_output).should eq(0)
      File.write(old_facts, old_output.to_s)

      File.write(source_path, "def after_update\nend\n")
      new_output = IO::Memory.new
      Chiasmus::FactsCLI.run(["--language", "crystal", "--dir", source_dir, "--cache-dir", cache_dir], output: new_output).should eq(0)
      File.write(new_facts, new_output.to_s)

      old_graph = Chiasmus::Graph::FactsSnapshot.load_graph_from_facts(old_facts) || raise "old snapshot missing"
      new_graph = Chiasmus::Graph::FactsSnapshot.load_graph_from_facts(new_facts) || raise "new snapshot missing"
      old_graph.defines.map(&.name).should contain("before_update")
      old_graph.defines.map(&.name).should_not contain("after_update")
      new_graph.defines.map(&.name).should contain("after_update")
      new_graph.defines.map(&.name).should_not contain("before_update")
    ensure
      Chiasmus::Graph::GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(dir)
    end
  end

  it "emits timing profile data to stderr when profiling is enabled" do
    dir = File.join(Dir.tempdir, "chiasmus-facts-cli-profile-#{Random::Secure.hex(8)}")
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
        ["--language", "crystal", "--dir", source_dir, "--profile"],
        output: output,
        error: error
      )

      exit_code.should eq(0)
      output.to_s.should contain("% chiasmus-facts language=crystal dir=#{source_dir} files=1")
      stderr = error.to_s
      stderr.should contain("[chiasmus-facts profile]")
      stderr.should contain("files=1")
      stderr.should contain("read_files_ms=")
      stderr.should contain("extract_graph_ms=")
      stderr.should contain("facts_render_ms=")
      stderr.should contain("flush_cache_ms=")
      stderr.should contain("total_ms=")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "excludes paths matching --exclude globs" do
    dir = File.join(Dir.tempdir, "chiasmus-facts-cli-exclude-#{Random::Secure.hex(8)}")
    keep_dir = File.join(dir, "keep")
    skip_dir = File.join(dir, "debugger")
    Dir.mkdir_p(keep_dir)
    Dir.mkdir_p(skip_dir)
    File.write(File.join(keep_dir, "kept.cr"), "def kept_method\nend\n")
    File.write(File.join(skip_dir, "skipped.cr"), "def skipped_method\nend\n")

    output = IO::Memory.new
    error = IO::Memory.new

    begin
      exit_code = Chiasmus::FactsCLI.run(
        ["--language", "crystal", "--dir", dir, "--exclude", "debugger"],
        output: output,
        error: error
      )

      exit_code.should eq(0)
      text = output.to_s
      text.should contain("files=1")
      text.should contain("kept_method")
      text.should_not contain("skipped_method")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
