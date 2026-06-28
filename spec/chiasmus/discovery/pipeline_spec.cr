require "../../spec_helper"
require "tree_sitter"
require "file_utils"
require "../../../src/chiasmus/utils/timeout"

vendor_dir = File.expand_path("../../../grammars", __DIR__)
if Dir.exists?(vendor_dir)
  Chiasmus::Discovery.register_grammar_directory(vendor_dir)
end

struct MissingGrammarExtractor < Chiasmus::Discovery::LanguageExtractor
  def language : String
    "missing"
  end

  def extensions : Array(String)
    [".missing"]
  end

  def grammar_language : String
    "definitely-missing-grammar"
  end

  def extract(
    root_node : TreeSitter::Node,
    source : String,
    file_path : String,
  ) : Array(Chiasmus::Discovery::Item)
    [] of Chiasmus::Discovery::Item
  end
end

struct SlowTypeScriptExtractor < Chiasmus::Discovery::LanguageExtractor
  @@mutex = Mutex.new
  @@active = 0
  @@peak = 0

  def self.reset_counts_for_test : Nil
    @@mutex.synchronize do
      @@active = 0
      @@peak = 0
    end
  end

  def self.peak_for_test : Int32
    @@mutex.synchronize { @@peak }
  end

  def language : String
    "slow-typescript"
  end

  def extensions : Array(String)
    [".ts"]
  end

  def grammar_language : String
    "typescript"
  end

  def extract(
    root_node : TreeSitter::Node,
    source : String,
    file_path : String,
  ) : Array(Chiasmus::Discovery::Item)
    @@mutex.synchronize do
      @@active += 1
      @@peak = Math.max(@@peak, @@active)
    end

    sleep 20.milliseconds

    [Chiasmus::Discovery::Item.new(
      id: "#{file_path}::function::#{File.basename(file_path, ".ts")}",
      kind: "function",
      scope: "source",
      name: File.basename(file_path, ".ts"),
      file: file_path,
    )]
  ensure
    @@mutex.synchronize do
      @@active -= 1
    end
  end
end

describe Chiasmus::Discovery::Pipeline do
  it "discovers files in a directory" do
    dir = File.join(Dir.tempdir, "chiasmus-pipe-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      File.write(File.join(dir, "app.ts"), "class App {}\nfunction main() {}\n")

      pipeline = Chiasmus::Discovery::Pipeline.new([
        Chiasmus::Discovery::TypeScriptExtractor.new,
      ])

      result = pipeline.discover(dir)
      result.parser_mode.should eq("tree-sitter")
      result.items.size.should be >= 2

      classes = result.items.select { |i| i.kind == "class" }
      classes.map(&.name).should contain("App")

      functions = result.items.select { |i| i.kind == "function" }
      functions.map(&.name).should contain("main")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "processes multiple files concurrently" do
    dir = File.join(Dir.tempdir, "chiasmus-pipe-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      File.write(File.join(dir, "a.ts"), "function a() {}\n")
      File.write(File.join(dir, "b.ts"), "function b() {}\n")
      File.write(File.join(dir, "c.ts"), "function c() {}\n")

      pipeline = Chiasmus::Discovery::Pipeline.new([
        Chiasmus::Discovery::TypeScriptExtractor.new,
      ], max_concurrent: 2)

      result = pipeline.discover(dir)
      funcs = result.items.select { |i| i.kind == "function" }.map(&.name)
      funcs.should contain("a")
      funcs.should contain("b")
      funcs.should contain("c")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "reads directory files with bounded concurrency during scan" do
    dir = File.join(Dir.tempdir, "chiasmus-pipe-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)

    begin
      File.write(File.join(dir, "a.ts"), "function a() {}\n")
      File.write(File.join(dir, "b.ts"), "function b() {}\n")
      File.write(File.join(dir, "c.ts"), "function c() {}\n")

      pipeline = Chiasmus::Discovery::Pipeline.new([
        Chiasmus::Discovery::TypeScriptExtractor.new,
      ], max_concurrent: 2)

      entered = Channel(String).new(3)
      release = Channel(Bool).new(3)
      result_channel = Channel(Chiasmus::Discovery::Result).new(1)

      begin
        Chiasmus::Discovery::Pipeline.set_before_scan_file_read_hook_for_test do |path|
          entered.send(File.basename(path))
          release.receive
        end

        spawn do
          result_channel.send(pipeline.discover(dir))
        end

        first = Chiasmus::Utils::Timeout.with_timeout_async(500, entered)
        second = Chiasmus::Utils::Timeout.with_timeout_async(500, entered)
        first.should_not be_nil
        second.should_not be_nil

        select
        when entered.receive
          fail("expected directory scan to honor max_concurrent before releasing a blocked read")
        when timeout 50.milliseconds
        end

        release.send(true)
        third = Chiasmus::Utils::Timeout.with_timeout_async(500, entered)
        third.should_not be_nil

        2.times { release.send(true) }

        result = Chiasmus::Utils::Timeout.with_timeout_async(1_000, result_channel)
        result.should_not be_nil
        result.not_nil!.items.select { |i| i.kind == "function" }.map(&.name).to_set.should eq(Set{"a", "b", "c"})
      ensure
        Chiasmus::Discovery::Pipeline.clear_before_scan_file_read_hook_for_test
      end
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "respects the bounded concurrency limit while processing files" do
    SlowTypeScriptExtractor.reset_counts_for_test

    pipeline = Chiasmus::Discovery::Pipeline.new([
      SlowTypeScriptExtractor.new,
    ], max_concurrent: 2)

    files = [
      {"a.ts", "function a() {}\n"},
      {"b.ts", "function b() {}\n"},
      {"c.ts", "function c() {}\n"},
      {"d.ts", "function d() {}\n"},
    ]

    result = pipeline.discover_files(files)

    result.items.map(&.name).to_set.should eq(Set{"a", "b", "c", "d"})
    SlowTypeScriptExtractor.peak_for_test.should be > 1
    SlowTypeScriptExtractor.peak_for_test.should be <= 2
  end

  it "returns empty result for unsupported extensions" do
    dir = File.join(Dir.tempdir, "chiasmus-pipe-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      File.write(File.join(dir, "notes.txt"), "hello")

      pipeline = Chiasmus::Discovery::Pipeline.new([
        Chiasmus::Discovery::TypeScriptExtractor.new,
      ])

      result = pipeline.discover(dir)
      result.items.should be_empty
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "supports multiple languages via registry" do
    dir = File.join(Dir.tempdir, "chiasmus-pipe-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      File.write(File.join(dir, "app.ts"), "class TSApp {}\n")
      File.write(File.join(dir, "script.py"), "class PyApp:\n  pass\n")

      pipeline = Chiasmus::Discovery::Pipeline.new([
        Chiasmus::Discovery::TypeScriptExtractor.new,
        Chiasmus::Discovery::PythonExtractor.new,
      ])

      result = pipeline.discover(dir)
      classes = result.items.select { |i| i.kind == "class" }.map(&.name)
      classes.should contain("TSApp")
      classes.should contain("PyApp")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "lists supported extensions and languages" do
    pipeline = Chiasmus::Discovery::Pipeline.new([
      Chiasmus::Discovery::TypeScriptExtractor.new,
      Chiasmus::Discovery::PythonExtractor.new,
    ])

    pipeline.supported_extensions.should contain(".ts")
    pipeline.supported_extensions.should contain(".py")
    pipeline.languages.should contain("typescript")
    pipeline.languages.should contain("python")
  end

  it "deduplicates items across files" do
    dir = File.join(Dir.tempdir, "chiasmus-pipe-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      File.write(File.join(dir, "a.ts"), "function shared() {}\n")
      File.write(File.join(dir, "b.ts"), "function shared() {}\n")

      pipeline = Chiasmus::Discovery::Pipeline.new([
        Chiasmus::Discovery::TypeScriptExtractor.new,
      ])

      result = pipeline.discover(dir)
      shared = result.items.select { |i| i.name == "shared" }
      # Different files → different IDs, both kept
      shared.size.should eq(2)
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "accounts for files whose grammar cannot be loaded without waiting for the global timeout" do
    pipeline = Chiasmus::Discovery::Pipeline.new([
      MissingGrammarExtractor.new,
    ])

    result = Chiasmus::Utils::Timeout.with_timeout(200) do
      pipeline.discover_files([
        {"test.missing", "noop"},
      ])
    end

    result.should_not be_nil
    resolved = result || raise "expected pipeline result"
    resolved.items.should be_empty
    resolved.parser_mode.should eq("tree-sitter")
  end

  it "returns discover_files_async through a channel boundary before releasing the result" do
    entered = Channel(Bool).new(1)
    release = Channel(Bool).new(1)

    pipeline = Chiasmus::Discovery::Pipeline.new([
      Chiasmus::Discovery::TypeScriptExtractor.new,
    ])

    begin
      Chiasmus::Discovery::Pipeline.set_before_async_result_send_hook_for_test do
        entered.send(true)
        release.receive
      end

      result_channel = pipeline.discover_files_async([
        {"app.ts", "function main() {}\n"},
      ])

      Chiasmus::Utils::Timeout.with_timeout_async(500, entered).should eq(true)

      select
      when value = result_channel.receive
        fail("expected discover_files_async to remain blocked at async result boundary, got #{value.inspect}")
      when timeout 50.milliseconds
      end

      release.send(true)

      result = Chiasmus::Utils::Timeout.with_timeout_async(1_000, result_channel)
      result.should_not be_nil

      async_result = result || raise "expected async discovery result"
      async_result.error.should be_nil
      async_result.value.should_not be_nil
      async_result.value.not_nil!.items.map(&.name).should contain("main")
    ensure
      Chiasmus::Discovery::Pipeline.clear_before_async_result_send_hook_for_test
    end
  end
end
