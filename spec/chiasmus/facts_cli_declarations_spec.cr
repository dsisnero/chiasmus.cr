require "../spec_helper"
require "../../src/chiasmus/parity"

describe Chiasmus::FactsCLI do
  it "rejects typed export for languages without a typed extraction adapter" do
    dir = File.join(Dir.tempdir, "chiasmus-facts-unsupported-#{Random::Secure.hex(8)}")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "sample.ts"), "export function sample() {}\n")
    error = IO::Memory.new

    begin
      code = Chiasmus::FactsCLI.run(
        ["--language", "typescript", "--dir", dir, "--declarations-out", File.join(dir, "declarations.jsonl")],
        output: IO::Memory.new,
        error: error
      )
      code.should eq(1)
      error.to_s.should contain("typed declaration export")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "refuses to overwrite an input source file with the declarations sidecar" do
    dir = File.join(Dir.tempdir, "chiasmus-facts-sidecar-collision-#{Random::Secure.hex(8)}")
    FileUtils.mkdir_p(dir)
    source_path = File.join(dir, "sample.cr")
    source = "def preserved\nend\n"
    File.write(source_path, source)
    error = IO::Memory.new

    begin
      code = Chiasmus::FactsCLI.run(
        ["--language", "crystal", "--dir", dir, "--declarations-out", source_path],
        output: IO::Memory.new,
        error: error
      )
      code.should eq(1)
      error.to_s.should contain("must not overwrite a source file")
      File.read(source_path).should eq(source)
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "writes one typed declaration result per input file without changing facts stdout" do
    dir = File.join(Dir.tempdir, "chiasmus-facts-declarations-#{Random::Secure.hex(8)}")
    source_dir = File.join(dir, "src")
    declarations_path = File.join(dir, "declarations.jsonl")
    FileUtils.mkdir_p(source_dir)
    FileUtils.mkdir_p(File.join(dir, ".git"))
    File.write(File.join(dir, ".git", "HEAD"), "ref: refs/heads/main\n")
    first_path = File.join(source_dir, "first.cr")
    second_path = File.join(source_dir, "second.cr")
    File.write(first_path, "module Demo\n  class Widget\n    def run(value : Int32) : String\n    end\n  end\nend\n")
    File.write(second_path, "module Other\n  def self.helper\n  end\nend\n")

    plain_output = IO::Memory.new
    plain_error = IO::Memory.new
    sidecar_output = IO::Memory.new
    sidecar_error = IO::Memory.new

    begin
      Chiasmus::FactsCLI.run(["--language", "crystal", "--dir", source_dir], output: plain_output, error: plain_error).should eq(0), plain_error.to_s
      Chiasmus::FactsCLI.run(
        ["--language", "crystal", "--dir", source_dir, "--declarations-out", declarations_path],
        output: sidecar_output,
        error: sidecar_error
      ).should eq(0), sidecar_error.to_s

      sidecar_output.to_s.should eq(plain_output.to_s)
      lines = File.read_lines(declarations_path)
      lines.size.should eq(2)
      results = lines.map { |line| JSON.parse(line) }
      results.map { |result| result["declarations"].as_a.size }.sum.should be > 0

      declarations = results.flat_map { |result| result["declarations"].as_a }
      run = declarations.find { |declaration| declaration["name"].as_s == "run" } || raise "missing typed run declaration"
      run["kind"].as_s.should eq("method")
      run["qualified_name"].as_s.should eq("Demo.Widget.run")
      run["legacy_aliases"].as_a.map(&.as_s).should eq(["#{first_path}::function::Demo.Widget.run"])
      run["declaration_id"].as_s.should start_with("decl:v1:")
      run["occurrence_id"].as_s.should start_with("occ:v1:")
      results.flat_map { |result| result["declarations"].as_a }.map { |declaration| declaration["file"].as_s }.uniq.sort.should eq([first_path, second_path].sort)
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "keeps the declarations sidecar coherent across cache cold, warm, and edited runs" do
    dir = File.join(Dir.tempdir, "chiasmus-facts-declarations-cache-#{Random::Secure.hex(8)}")
    source_dir = File.join(dir, "src")
    cache_dir = File.join(dir, "cache")
    declarations_path = File.join(dir, "declarations.jsonl")
    FileUtils.mkdir_p(source_dir)
    source_path = File.join(source_dir, "sample.cr")

    run_cli = -> do
      output = IO::Memory.new
      error = IO::Memory.new
      code = Chiasmus::FactsCLI.run(
        ["--language", "crystal", "--dir", source_dir, "--cache-dir", cache_dir, "--declarations-out", declarations_path],
        output: output,
        error: error
      )
      code.should eq(0), error.to_s
      File.read_lines(declarations_path).map { |line| JSON.parse(line) }
    end

    begin
      File.write(source_path, "module Demo\n  def before_edit\n  end\nend\n")
      cold = run_cli.call
      warm = run_cli.call
      cold.should eq(warm)
      cold.size.should eq(1)
      cold.first["declarations"].as_a.map { |declaration| declaration["name"].as_s }.should contain("before_edit")

      File.write(source_path, "module Demo\n  def after_edit\n  end\nend\n")
      edited = run_cli.call
      edited.size.should eq(1)
      names = edited.first["declarations"].as_a.map { |declaration| declaration["name"].as_s }
      names.should contain("after_edit")
      names.should_not contain("before_edit")
    ensure
      Chiasmus::Graph::GraphCache.flush_async_writes
      Chiasmus::Graph::GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(dir)
    end
  end

  it "feeds exported local IDs into the parity bundle" do
    dir = File.join(Dir.tempdir, "chiasmus-facts-parity-#{Random::Secure.hex(8)}")
    source_dir = File.join(dir, "java")
    target_dir = File.join(dir, "crystal")
    bundle_dir = File.join(dir, "bundle")
    FileUtils.mkdir_p(source_dir)
    FileUtils.mkdir_p(target_dir)
    File.write(File.join(source_dir, "Worker.java"), "class Worker { void solve() {} }\n")
    File.write(File.join(target_dir, "worker.cr"), "class Worker\n  def self.solve_cr\n  end\nend\n")
    source_facts = File.join(dir, "source.pl")
    target_facts = File.join(dir, "target.pl")
    source_declarations = File.join(dir, "source.jsonl")
    target_declarations = File.join(dir, "target.jsonl")
    rules = File.join(dir, "rules.yml")
    File.write(rules, "version: 1\nsource_language: java\ntarget_language: crystal\nrenames:\n  - source: solve\n    target: solve_cr\n")

    begin
      source_output = IO::Memory.new
      target_output = IO::Memory.new
      Chiasmus::FactsCLI.run(["--language", "java", "--dir", source_dir, "--declarations-out", source_declarations], output: source_output).should eq(0)
      Chiasmus::FactsCLI.run(["--language", "crystal", "--dir", target_dir, "--declarations-out", target_declarations], output: target_output).should eq(0)
      File.write(source_facts, source_output.to_s)
      File.write(target_facts, target_output.to_s)

      error = IO::Memory.new
      Chiasmus::Parity::CLI.run([
        "--source-facts", source_facts,
        "--crystal-facts", target_facts,
        "--source-declarations", source_declarations,
        "--target-declarations", target_declarations,
        "--map-rules", rules,
        "--bundle-dir", bundle_dir,
      ], IO::Memory.new, error).should eq(0), error.to_s
      records = File.read_lines(File.join(bundle_dir, "port-concepts.jsonl")).map { |line| JSON.parse(line) }
      matched = records.find { |record| record["source_name"].as_s == "Worker.solve" } || raise "missing solve mapping"
      matched["source_declaration_id"].as_s.should start_with("decl:v1:")
      matched["target_declaration_id"].as_s.should start_with("decl:v1:")
      matched["port_concept_id"].as_s.should start_with("port:v1:")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
