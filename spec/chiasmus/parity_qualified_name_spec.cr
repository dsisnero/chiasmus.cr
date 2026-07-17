require "../spec_helper"

module ParityQualifiedNameSpecHelpers
  extend self

  def write_temp_facts(name : String, graph : Chiasmus::Graph::CodeGraph) : String
    dir = File.join(Dir.tempdir, "chiasmus-parity-qn-#{name}-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    path = File.join(dir, "facts.pl")
    File.write(path, Chiasmus::Graph::Facts.graph_to_prolog(graph))
    path
  end
end

describe Chiasmus::Parity::Structural do
  it "preserves qualified_name on defines when loading raw facts" do
    facts_path = ParityQualifiedNameSpecHelpers.write_temp_facts(
      "load",
      Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(
            file: "src/session.cr",
            name: "run",
            kind: Chiasmus::Graph::SymbolKind::Method,
            span: Chiasmus::Graph::Span.line_range(3),
            qualified_name: "SolverSession.run",
          ),
        ],
      )
    )

    begin
      loaded = Chiasmus::Parity::Structural.load_facts(facts_path)
      loaded.graph.defines.first.qualified_name.should eq("SolverSession.run")
    ensure
      FileUtils.rm_rf(File.dirname(facts_path))
    end
  end

  it "uses preserved qualified names when structurally comparing raw facts" do
    source_path = ParityQualifiedNameSpecHelpers.write_temp_facts(
      "source",
      Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(
            file: "src/session.ts",
            name: "solve",
            kind: Chiasmus::Graph::SymbolKind::Method,
            span: Chiasmus::Graph::Span.line_range(3),
            qualified_name: "SolverSession.solve",
          ),
        ],
      )
    )
    target_path = ParityQualifiedNameSpecHelpers.write_temp_facts(
      "target",
      Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(
            file: "src/session.cr",
            name: "run",
            kind: Chiasmus::Graph::SymbolKind::Method,
            span: Chiasmus::Graph::Span.line_range(3),
            qualified_name: "SolverSession.run",
          ),
        ],
      )
    )

    begin
      source_facts = Chiasmus::Parity::Structural.load_facts(source_path)
      target_facts = Chiasmus::Parity::Structural.load_facts(target_path)

      report = Chiasmus::Parity::Structural.compare(
        source_facts,
        "SolverSession.solve",
        target_facts,
        "SolverSession.run",
        source_file: "src/session.ts",
        target_file: "src/session.cr",
      )

      report.source_defined.should be_true
      report.target_defined.should be_true
      report.status.should eq("structural_match")
    ensure
      FileUtils.rm_rf(File.dirname(source_path))
      FileUtils.rm_rf(File.dirname(target_path))
    end
  end
end
