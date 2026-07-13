require "../spec_helper"

describe Chiasmus::FactsCLI do
  it "flushes async file cache writes before returning when cache is enabled" do
    dir = File.join(Dir.tempdir, "chiasmus-facts-cli-#{Random::Secure.hex(8)}")
    cache_dir = File.join(dir, "cache")
    source_dir = File.join(dir, "src")
    Dir.mkdir_p(source_dir)
    File.write(File.join(source_dir, "sample.cr"), <<-CR)
      module Demo
        def self.run
        end
      end
    CR

    entered = Channel(Bool).new(1)
    release = Channel(Bool).new(1)
    result = Channel(Int32).new(1)

    Chiasmus::Graph::GraphCache.set_before_file_cache_write_hook_for_test do
      entered.send(true)
      release.receive?
    end

    begin
      spawn do
        output = IO::Memory.new
        error = IO::Memory.new
        exit_code = Chiasmus::FactsCLI.run(
          ["--language", "crystal", "--dir", source_dir, "--cache-dir", cache_dir],
          output: output,
          error: error
        )
        result.send(exit_code)
      end

      entered.receive.should be_true

      select
      when exit_code = result.receive
        fail("expected chiasmus-facts to wait for async cache flush, returned #{exit_code} early")
      else
      end

      release.send(true)
      result.receive.should eq(0)

      paths = Chiasmus::Graph::GraphCache.resolve_cache_paths(cache_dir)
      File.exists?(paths["database_path"]).should be_true
      File.exists?(paths["manifest_path"]).should be_false
    ensure
      release.send(true) rescue nil
      Chiasmus::Graph::GraphCache.clear_before_file_cache_write_hook_for_test
      Chiasmus::Graph::GraphCache.flush_async_writes
      Chiasmus::Graph::GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(dir)
    end
  end
end
