require "json"
require "../../spec_helper"
require "../../../src/chiasmus/parity"
require "../../../src/chiasmus/graph/facts"

private module PortConceptIdSpecSupport
  extend self

  def graph(file : String, definitions : Array(Tuple(String, String, Chiasmus::Graph::SymbolKind))) : Chiasmus::Graph::CodeGraph
    Chiasmus::Graph::CodeGraph.new(
      defines: definitions.map do |name, qualified_name, kind|
        Chiasmus::Graph::DefinesFact.new(
          file: file,
          name: name,
          kind: kind,
          span: Chiasmus::Graph::Span.line_range(1),
          qualified_name: qualified_name,
        )
      end,
      calls: [] of Chiasmus::Graph::CallsFact,
      imports: [] of Chiasmus::Graph::ImportsFact,
      exports: [] of Chiasmus::Graph::ExportsFact,
      contains: [] of Chiasmus::Graph::ContainsFact,
    )
  end

  def bundle(source : Chiasmus::Graph::CodeGraph, target : Chiasmus::Graph::CodeGraph) : Array(JSON::Any)
    dir = File.join(Dir.tempdir, "chiasmus-port-concept-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    source_path = File.join(dir, "source.pl")
    target_path = File.join(dir, "target.pl")
    rules_path = File.join(dir, "rules.yml")
    output_dir = File.join(dir, "bundle")
    File.write(source_path, Chiasmus::Graph::Facts.graph_to_prolog(source))
    File.write(target_path, Chiasmus::Graph::Facts.graph_to_prolog(target))
    File.write(rules_path, "version: 1\nsource_language: java\ntarget_language: crystal\nrenames:\n  - source: ReviewedSourceName\n    target: ReviewedTargetName\n")

    error = IO::Memory.new
    code = Chiasmus::Parity::CLI.run(
      ["--source-facts", source_path, "--crystal-facts", target_path, "--map-rules", rules_path, "--bundle-dir", output_dir],
      IO::Memory.new,
      error,
    )
    code.should eq(0), error.to_s
    sidecar_path = File.join(output_dir, "port-concepts.jsonl")
    File.exists?(sidecar_path).should be_true
    return [] of JSON::Any unless File.exists?(sidecar_path)
    File.read_lines(sidecar_path).reject(&.empty?).map { |line| JSON.parse(line) }
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end

describe "reviewed PortConceptId sidecar" do
  it "keeps a matched concept ID stable when checkout roots and file paths shift" do
    kind = Chiasmus::Graph::SymbolKind::Method
    source_definitions = [{"ReviewedSourceName", "ReviewedSourceName", kind}]
    target_definitions = [{"ReviewedTargetName", "ReviewedTargetName", kind}]
    first = PortConceptIdSpecSupport.bundle(
      PortConceptIdSpecSupport.graph("/work/a/vendor/lib/ReviewedSourceName.java", source_definitions),
      PortConceptIdSpecSupport.graph("/work/a/src/reviewed_target_name.cr", target_definitions),
    )
    shifted = PortConceptIdSpecSupport.bundle(
      PortConceptIdSpecSupport.graph("/other/checkout/vendor/lib/ReviewedSourceName.java", source_definitions),
      PortConceptIdSpecSupport.graph("/other/checkout/src/reviewed_target_name.cr", target_definitions),
    )

    first.size.should eq(1)
    first.first["status"].as_s.should eq("matched")
    first.first["basis"].as_s.should eq("renamed")
    first.first["port_concept_id"].as_s.should eq(shifted.first["port_concept_id"].as_s)
    first.first["port_concept_id"].as_s.should match(/\Aport:v1:[a-z0-9_-]+\z/)
  end

  it "leaves ambiguous and unmapped correspondences without a shared ID" do
    kind = Chiasmus::Graph::SymbolKind::Method
    source = PortConceptIdSpecSupport.graph("/work/vendor/lib/ReviewedSourceName.java", [
      {"ReviewedSourceName", "ReviewedSourceName", kind},
      {"orphan", "orphan", kind},
      {"ordinary", "ordinary", kind},
    ])
    target = PortConceptIdSpecSupport.graph("/work/src/targets.cr", [
      {"ReviewedTargetName", "ReviewedTargetName", kind},
      {"ReviewedTargetName", "Other::ReviewedTargetName", kind},
      {"ordinary", "ordinary", kind},
    ])

    records = PortConceptIdSpecSupport.bundle(source, target)
    ambiguous = records.find { |record| record["status"].as_s == "ambiguous" }
    unmapped = records.find { |record| record["status"].as_s == "unmapped_source" }
    ambiguous.should_not be_nil
    unmapped.should_not be_nil
    direct = records.find { |record| record["source_id"].as_s.ends_with?("::ordinary") }
    direct.should_not be_nil
    if record = ambiguous
      record["port_concept_id"].raw.should be_nil
    end
    if record = unmapped
      record["port_concept_id"].raw.should be_nil
    end
    if record = direct
      record["port_concept_id"].raw.should be_nil
    end
  end

  it "does not assign a concept to duplicate same-name declarations" do
    kind = Chiasmus::Graph::SymbolKind::Method
    first = PortConceptIdSpecSupport.graph("/work/a.java", [{"ReviewedSourceName", "ReviewedSourceName", kind}])
    second = PortConceptIdSpecSupport.graph("/work/b.java", [{"ReviewedSourceName", "ReviewedSourceName", kind}])
    source = Chiasmus::Graph::CodeGraph.new(
      defines: first.defines + second.defines,
      calls: [] of Chiasmus::Graph::CallsFact,
      imports: [] of Chiasmus::Graph::ImportsFact,
      exports: [] of Chiasmus::Graph::ExportsFact,
      contains: [] of Chiasmus::Graph::ContainsFact,
    )
    target = PortConceptIdSpecSupport.graph("/work/a.cr", [
      {"ReviewedTargetName", "ReviewedTargetName", kind},
    ])

    records = PortConceptIdSpecSupport.bundle(source, target)
    records.size.should eq(2)
    records.each { |record| record["port_concept_id"].raw.should be_nil }
  end
end
