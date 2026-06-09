require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/analyses"
require "../../../src/chiasmus/graph/diff"
require "../../../src/chiasmus/graph/cache"
require "file_utils"

include Chiasmus::Graph

describe "Diff analysis with snapshots" do
  it "detects added nodes via GraphDiffer.diff" do
    graph_before = CodeGraph.new(defines: [
      DefinesFact.new(file: "a.go", name: "foo", kind: SymbolKind::Function, line: 1),
    ])
    graph_after = CodeGraph.new(defines: [
      DefinesFact.new(file: "a.go", name: "foo", kind: SymbolKind::Function, line: 1),
      DefinesFact.new(file: "b.go", name: "baz", kind: SymbolKind::Function, line: 1),
    ])
    result = GraphDiffer.diff(graph_before, graph_after)
    result.added_nodes.should contain("baz")
  end

  it "detects removed nodes via GraphDiffer.diff" do
    graph_before = CodeGraph.new(defines: [
      DefinesFact.new(file: "a.go", name: "oldFunc", kind: SymbolKind::Function, line: 1),
      DefinesFact.new(file: "a.go", name: "kept", kind: SymbolKind::Function, line: 5),
    ])
    graph_after = CodeGraph.new(defines: [
      DefinesFact.new(file: "a.go", name: "kept", kind: SymbolKind::Function, line: 5),
    ])
    result = GraphDiffer.diff(graph_before, graph_after)
    result.removed_nodes.should contain("oldFunc")
  end

  it "round-trips snapshot through GraphCache" do
    cache_dir = File.join(Dir.tempdir, "chiasmus-diff-#{Random::Secure.hex(8)}")
    graph = CodeGraph.new(
      defines: [DefinesFact.new(file: "a.go", name: "hello", kind: SymbolKind::Function, line: 1)],
    )
    GraphCache.save_snapshot("test-snap", graph, cache_dir)
    loaded = GraphCache.load_snapshot("test-snap", cache_dir)
    loaded.should_not be_nil
    (loaded || raise("nil")).defines.map(&.name).should contain("hello")
    FileUtils.rm_rf(cache_dir)
  end

  it "AnalysisRequest accepts against field for snapshot name" do
    req = AnalysisRequest.new(analysis: AnalysisType::Diff, against: "baseline-2024")
    req.against.should eq("baseline-2024")
  end

  it "run_analysis_from_graph with diff no longer returns stub error" do
    cache_dir = File.join(Dir.tempdir, "chiasmus-diff-#{Random::Secure.hex(8)}")
    graph = CodeGraph.new(
      defines: [DefinesFact.new(file: "a.go", name: "foo", kind: SymbolKind::Function, line: 1)],
    )
    GraphCache.save_snapshot("base", graph, cache_dir)
    result = Analyses.run_analysis_from_graph(
      graph,
      AnalysisRequest.new(analysis: AnalysisType::Diff, against: "base"),
      snapshot_cache_dir: cache_dir,
    )
    json = result.result.as(String)
    json.should_not contain("not yet wired")
    FileUtils.rm_rf(cache_dir)
  end
end
