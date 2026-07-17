require "../spec_helper"

describe Chiasmus::FactsCLI do
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
end
