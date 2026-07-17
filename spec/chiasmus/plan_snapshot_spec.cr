require "../spec_helper"

describe Chiasmus::Plan do
  it "loads the cached codegraph snapshot referenced by a facts file" do
    dir = File.join(Dir.tempdir, "chiasmus-plan-load-facts-#{Random::Secure.hex(8)}")
    cache_dir = File.join(dir, "cache")
    facts_path = File.join(dir, "facts.pl")
    Dir.mkdir_p(dir)

    graph = Chiasmus::Graph::CodeGraph.new(
      defines: [
        Chiasmus::Graph::DefinesFact.new(file: "src/app.ts", name: "main", kind: Chiasmus::Graph::SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1)),
      ],
      calls: [] of Chiasmus::Graph::CallsFact,
      exports: [
        Chiasmus::Graph::ExportsFact.new(file: "src/app.ts", name: "main"),
      ],
      contains: [] of Chiasmus::Graph::ContainsFact,
      imports: [
        Chiasmus::Graph::ImportsFact.new(file: "src/app.ts", name: "dep", source: "./dep"),
      ],
    )
    metadata = Chiasmus::Graph::FactsSnapshot::Metadata.new(
      cache_dir: cache_dir,
      repo_key: "plan-spec",
      snapshot: "seed",
    )

    begin
      Chiasmus::Graph::GraphCache.save_snapshot("seed", graph, cache_dir, repo_key: "plan-spec")
      File.write(facts_path, <<-PL)
% chiasmus-facts language=typescript dir=#{dir} files=1
#{Chiasmus::Graph::FactsSnapshot.metadata_line(metadata)}
entry_point('main').
entry_point_file('src/app.ts', 'main').
PL

      parsed = Chiasmus::Plan.load_facts(facts_path)
      parsed.graph.defines.map(&.name).should eq(["main"])
      parsed.graph.imports.map(&.source).should eq(["./dep"])
      parsed.entry_points.should eq(["main"])
      parsed.semantic_entry_points.should eq(["src/app.ts::function::main"])
    ensure
      Chiasmus::Graph::GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(dir)
    end
  end
end
