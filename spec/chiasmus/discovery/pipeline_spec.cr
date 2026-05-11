require "../../spec_helper"
require "tree_sitter"
require "file_utils"

vendor_dir = File.expand_path("../../../vendor/grammars", __DIR__)
if Dir.exists?(vendor_dir)
  Chiasmus::Discovery.register_grammar_directory(vendor_dir)
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
end
