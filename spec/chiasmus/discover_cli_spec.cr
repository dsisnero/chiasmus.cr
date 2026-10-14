require "spec"
require "../../src/chiasmus/discover_cli"
require "../../src/chiasmus/facts_cli"
require "tree-sitter-manager"
require "file_utils"

describe Chiasmus::DiscoverCLI do
  it "shares cached extraction with facts and sees edited declarations" do
    dir = File.join(Dir.tempdir, "discover-cli-shared-#{Random::Secure.hex(8)}")
    source_dir = File.join(dir, "src")
    cache_dir = File.join(dir, "cache")
    Dir.mkdir_p(source_dir)
    source_path = File.join(source_dir, "Greeter.java")
    File.write(source_path, "class Greeter { void greet() {} }")

    begin
      facts_output = IO::Memory.new
      Chiasmus::FactsCLI.run(["--language", "java", "--dir", source_dir, "--cache-dir", cache_dir], output: facts_output).should eq(0)

      cached_output = IO::Memory.new
      Chiasmus::DiscoverCLI.run(["--language", "java", "--dir", source_dir, "--cache-dir", cache_dir], output: cached_output).should eq(0)
      uncached_output = IO::Memory.new
      Chiasmus::DiscoverCLI.run(["--language", "java", "--dir", source_dir], output: uncached_output).should eq(0)
      cached_output.to_s.should eq(uncached_output.to_s)

      File.write(source_path, "class Greeter { void greet() {} void wave() {} }")
      edited_output = IO::Memory.new
      Chiasmus::DiscoverCLI.run(["--language", "java", "--dir", source_dir, "--cache-dir", cache_dir], output: edited_output).should eq(0)
      edited_output.to_s.should contain("method::wave")
    ensure
      Chiasmus::Graph::GraphCache.flush_async_writes
      Chiasmus::Graph::GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(dir)
    end
  end

  it "reads source files with bounded concurrency during CLI scan" do
    dir = File.join(Dir.tempdir, "discover-cli-scan-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)

    begin
      {
        "a.ts" => "export function a() {}\n",
        "b.ts" => "export function b() {}\n",
        "c.ts" => "export function c() {}\n",
      }.each do |name, content|
        File.write(File.join(dir, name), content)
      end

      entered = Channel(String).new(3)
      release = Channel(Bool).new(3)
      result_channel = Channel(Array(Tuple(String, String))).new(1)

      begin
        Chiasmus::DiscoverCLI.scan_max_concurrent_for_test = 2
        Chiasmus::DiscoverCLI.set_before_scan_file_read_hook_for_test do |path|
          entered.send(File.basename(path))
          release.receive
        end

        spawn do
          result_channel.send(Chiasmus::DiscoverCLI.scan_files_for_test("typescript", dir))
        end

        first = TreeSitterManager::Timeout.with_timeout_async(500, entered)
        second = TreeSitterManager::Timeout.with_timeout_async(500, entered)
        first.should_not be_nil
        second.should_not be_nil

        select
        when entered.receive
          fail("expected discover CLI scan to honor the bounded read limit")
        when timeout 50.milliseconds
        end

        release.send(true)
        third = TreeSitterManager::Timeout.with_timeout_async(500, entered)
        third.should_not be_nil
        2.times { release.send(true) }

        result = TreeSitterManager::Timeout.with_timeout_async(1_000, result_channel)
        result.should_not be_nil
        entries = result || raise "expected discovered entries"
        entries.map(&.[0]).to_set.should eq(Set{"a.ts", "b.ts", "c.ts"})
      ensure
        Chiasmus::DiscoverCLI.clear_before_scan_file_read_hook_for_test
        Chiasmus::DiscoverCLI.clear_scan_max_concurrent_for_test
      end
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
