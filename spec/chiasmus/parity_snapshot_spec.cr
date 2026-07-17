require "../spec_helper"

describe Chiasmus::Parity::Structural do
  it "loads the cached codegraph snapshot referenced by a facts file" do
    dir = File.join(Dir.tempdir, "chiasmus-parity-load-facts-#{Random::Secure.hex(8)}")
    cache_dir = File.join(dir, "cache")
    facts_path = File.join(dir, "facts.pl")
    Dir.mkdir_p(dir)

    graph = Chiasmus::Graph::CodeGraph.new(
      defines: [
        Chiasmus::Graph::DefinesFact.new(file: "src/config.ts", name: "loadConfig", kind: Chiasmus::Graph::SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1)),
      ],
      calls: [] of Chiasmus::Graph::CallsFact,
      imports: [
        Chiasmus::Graph::ImportsFact.new(file: "src/config.ts", name: "fs", source: "./fs"),
      ],
      exports: [
        Chiasmus::Graph::ExportsFact.new(file: "src/config.ts", name: "loadConfig"),
      ],
      contains: [] of Chiasmus::Graph::ContainsFact,
    )
    metadata = Chiasmus::Graph::FactsSnapshot::Metadata.new(
      cache_dir: cache_dir,
      repo_key: "parity-spec",
      snapshot: "source",
    )

    begin
      Chiasmus::Graph::GraphCache.save_snapshot("source", graph, cache_dir, repo_key: "parity-spec")
      File.write(facts_path, <<-PL)
% chiasmus-facts language=typescript dir=#{dir} files=1
#{Chiasmus::Graph::FactsSnapshot.metadata_line(metadata)}
entry_point('loadConfig').
entry_point_file('src/config.ts', 'loadConfig').
calls_in('src/config.ts', 'loadConfig', 'readFile').
PL

      loaded = Chiasmus::Parity::Structural.load_facts(facts_path)
      loaded.graph.imports.map(&.source).should eq(["./fs"])
      loaded.entry_points.should eq(["loadConfig"])
      loaded.entry_point_files.should eq([{"src/config.ts", "loadConfig"}])
      loaded.scoped_calls.map(&.callee).should eq(["readFile"])
    ensure
      Chiasmus::Graph::GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(dir)
    end
  end
end
