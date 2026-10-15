require "json"
require "../../spec_helper"
require "../../../src/chiasmus/parity"
require "../../../src/chiasmus/graph/facts"
require "../../../src/chiasmus/graph/file_extraction"

private module TypedDeclarationSidecarSpecSupport
  extend self

  alias Declaration = Chiasmus::Graph::FileExtraction::Declaration
  alias Result = Chiasmus::Graph::FileExtraction::Result

  def graph(file : String, name : String) : Chiasmus::Graph::CodeGraph
    Chiasmus::Graph::CodeGraph.new(
      defines: [Chiasmus::Graph::DefinesFact.new(
        file: file,
        name: name.split('.').last,
        kind: Chiasmus::Graph::SymbolKind::Method,
        span: Chiasmus::Graph::Span.line_range(1),
        qualified_name: name,
      )],
      calls: [] of Chiasmus::Graph::CallsFact,
      imports: [] of Chiasmus::Graph::ImportsFact,
      exports: [] of Chiasmus::Graph::ExportsFact,
      contains: [] of Chiasmus::Graph::ContainsFact,
    )
  end

  def declaration(
    language : String,
    file : String,
    name : String,
    declaration_id : String,
    legacy_alias : String,
  ) : Declaration
    Declaration.new(
      language: language,
      namespace: nil,
      owner: name.split('.')[0...-1].join('.'),
      kind: "method",
      name: name.split('.').last,
      qualified_name: name,
      file: file,
      span: Chiasmus::Graph::Span.line_range(1),
      ast_node_type: "method_declaration",
      extraction_method: "test_fixture",
      legacy_aliases: [legacy_alias],
      declaration_id: declaration_id,
      occurrence_id: "occ:v1:test",
    )
  end

  def bundle(
    source : Chiasmus::Graph::CodeGraph,
    target : Chiasmus::Graph::CodeGraph,
    source_results : Array(Result),
    target_results : Array(Result),
  ) : Array(JSON::Any)
    dir = File.join(Dir.tempdir, "chiasmus-typed-declarations-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    source_path = File.join(dir, "source.pl")
    target_path = File.join(dir, "target.pl")
    source_declarations_path = File.join(dir, "source-declarations.jsonl")
    target_declarations_path = File.join(dir, "target-declarations.jsonl")
    rules_path = File.join(dir, "rules.yml")
    output_dir = File.join(dir, "bundle")
    File.write(source_path, Chiasmus::Graph::Facts.graph_to_prolog(source))
    File.write(target_path, Chiasmus::Graph::Facts.graph_to_prolog(target))
    File.write(source_declarations_path, source_results.map(&.to_json).join('\n') + "\n")
    File.write(target_declarations_path, target_results.map(&.to_json).join('\n') + "\n")
    File.write(rules_path, "version: 1\nsource_language: java\ntarget_language: crystal\nrenames:\n  - source: solve\n    target: solve_cr\n")

    error = IO::Memory.new
    code = Chiasmus::Parity::CLI.run(
      [
        "--source-facts", source_path,
        "--crystal-facts", target_path,
        "--map-rules", rules_path,
        "--source-declarations", source_declarations_path,
        "--target-declarations", target_declarations_path,
        "--bundle-dir", output_dir,
      ],
      IO::Memory.new,
      error,
    )
    code.should eq(0), error.to_s
    return [] of JSON::Any unless code == 0

    File.read_lines(File.join(output_dir, "port-concepts.jsonl")).reject(&.empty?).map { |line| JSON.parse(line) }
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end

describe "typed declaration inputs for parity sidecar" do
  it "joins graph facts through legacy aliases and emits local declaration IDs" do
    source_file = "/work/vendor/src/Worker.java"
    target_file = "/work/src/worker.cr"
    source_id = "#{source_file}::method::Worker.solve"
    target_id = "#{target_file}::method::Worker.solve_cr"
    source = TypedDeclarationSidecarSpecSupport.graph(source_file, "Worker.solve")
    target = TypedDeclarationSidecarSpecSupport.graph(target_file, "Worker.solve_cr")
    source_result = TypedDeclarationSidecarSpecSupport::Result.new([
      TypedDeclarationSidecarSpecSupport.declaration("java", source_file, "Worker.solve", "decl:v1:java-worker-solve", source_id),
    ])
    target_result = TypedDeclarationSidecarSpecSupport::Result.new([
      TypedDeclarationSidecarSpecSupport.declaration("crystal", target_file, "Worker.solve_cr", "decl:v1:crystal-worker-solve", target_id),
    ])

    record = TypedDeclarationSidecarSpecSupport.bundle(source, target, [source_result], [target_result]).first
    record["source_declaration_id"].as_s.should eq("decl:v1:java-worker-solve")
    record["target_declaration_id"].as_s.should eq("decl:v1:crystal-worker-solve")
  end

  it "leaves stale and ambiguous aliases unjoined instead of guessing" do
    source_file = "/work/vendor/src/Worker.java"
    target_file = "/work/src/worker.cr"
    source_id = "#{source_file}::method::Worker.solve"
    target_id = "#{target_file}::method::Worker.solve_cr"
    source = TypedDeclarationSidecarSpecSupport.graph(source_file, "Worker.solve")
    target = TypedDeclarationSidecarSpecSupport.graph(target_file, "Worker.solve_cr")
    stale = TypedDeclarationSidecarSpecSupport::Result.new([
      TypedDeclarationSidecarSpecSupport.declaration("java", source_file, "Worker.solve", "decl:v1:stale", "/old/root/Worker.java::method::Worker.solve"),
    ])
    duplicate_one = TypedDeclarationSidecarSpecSupport::Result.new([
      TypedDeclarationSidecarSpecSupport.declaration("java", source_file, "Worker.solve", "decl:v1:ambiguous-one", source_id),
    ])
    duplicate_two = TypedDeclarationSidecarSpecSupport::Result.new([
      TypedDeclarationSidecarSpecSupport.declaration("java", source_file, "Worker.solve", "decl:v1:ambiguous-two", source_id),
    ])
    target_result = TypedDeclarationSidecarSpecSupport::Result.new([
      TypedDeclarationSidecarSpecSupport.declaration("crystal", target_file, "Worker.solve_cr", "decl:v1:crystal-worker-solve", target_id),
    ])

    stale_record = TypedDeclarationSidecarSpecSupport.bundle(source, target, [stale], [target_result]).first
    ambiguous_records = TypedDeclarationSidecarSpecSupport.bundle(source, target, [duplicate_one, duplicate_two], [target_result])

    stale_record["source_declaration_id"].raw.should be_nil
    stale_record["target_declaration_id"].as_s.should eq("decl:v1:crystal-worker-solve")
    ambiguous_records.size.should eq(1)
    ambiguous_records.first["source_declaration_id"].raw.should be_nil
  end

  it "does not join a declaration from the wrong source language" do
    source_file = "/work/vendor/src/Worker.java"
    target_file = "/work/src/worker.cr"
    source = TypedDeclarationSidecarSpecSupport.graph(source_file, "Worker.solve")
    target = TypedDeclarationSidecarSpecSupport.graph(target_file, "Worker.solve_cr")
    wrong_language = TypedDeclarationSidecarSpecSupport::Result.new([
      TypedDeclarationSidecarSpecSupport.declaration("crystal", source_file, "Worker.solve", "decl:v1:wrong-language", "#{source_file}::method::Worker.solve"),
    ])

    record = TypedDeclarationSidecarSpecSupport.bundle(source, target, [wrong_language], [] of TypedDeclarationSidecarSpecSupport::Result).first
    record["source_declaration_id"].raw.should be_nil
  end

  it "preserves local declaration IDs when both checkout paths move" do
    first_source_file = "/work/a/vendor/src/Worker.java"
    first_target_file = "/work/a/src/worker.cr"
    shifted_source_file = "/work/b/vendor/src/Worker.java"
    shifted_target_file = "/work/b/src/worker.cr"
    build_bundle = ->(source_file : String, target_file : String) do
      source_id = "#{source_file}::method::Worker.solve"
      target_id = "#{target_file}::method::Worker.solve_cr"
      source = TypedDeclarationSidecarSpecSupport.graph(source_file, "Worker.solve")
      target = TypedDeclarationSidecarSpecSupport.graph(target_file, "Worker.solve_cr")
      source_result = TypedDeclarationSidecarSpecSupport::Result.new([
        TypedDeclarationSidecarSpecSupport.declaration("java", source_file, "Worker.solve", "decl:v1:java-worker-solve", source_id),
      ])
      target_result = TypedDeclarationSidecarSpecSupport::Result.new([
        TypedDeclarationSidecarSpecSupport.declaration("crystal", target_file, "Worker.solve_cr", "decl:v1:crystal-worker-solve", target_id),
      ])
      TypedDeclarationSidecarSpecSupport.bundle(source, target, [source_result], [target_result]).first
    end

    first = build_bundle.call(first_source_file, first_target_file)
    shifted = build_bundle.call(shifted_source_file, shifted_target_file)
    first["source_declaration_id"].as_s.should eq(shifted["source_declaration_id"].as_s)
    first["target_declaration_id"].as_s.should eq(shifted["target_declaration_id"].as_s)
  end
end
