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

  it "GraphCache.default_cache_dir respects CHIASMUS_CACHE_DIR env var" do
    with_env({"CHIASMUS_CACHE_DIR" => "/custom/cache/path"}) do
      GraphCache.default_cache_dir.should eq("/custom/cache/path")
    end
  end

  it "GraphCache.default_cache_dir falls back to XDG_CACHE_HOME/chiasmus" do
    with_env({"CHIASMUS_CACHE_DIR" => nil, "XDG_CACHE_HOME" => "/xdg/cache"}) do
      GraphCache.default_cache_dir.should eq(File.join("/xdg/cache", "chiasmus"))
    end
  end

  it "GraphCache.default_cache_dir falls back to ~/.cache/chiasmus" do
    with_env({"CHIASMUS_CACHE_DIR" => nil, "XDG_CACHE_HOME" => nil}) do
      expected = File.join(Path.home.to_s, ".cache", "chiasmus")
      GraphCache.default_cache_dir.should eq(expected)
    end
  end

  it "GraphCache.default_max_bytes_per_repo respects env var" do
    with_env({"CHIASMUS_CACHE_MAX_PER_REPO" => "1048576"}) do
      GraphCache.default_max_bytes_per_repo.should eq(1048576)
    end
  end

  it "GraphCache.default_max_bytes_per_repo ignores invalid env values" do
    with_env({"CHIASMUS_CACHE_MAX_PER_REPO" => "not-a-number"}) do
      GraphCache.default_max_bytes_per_repo.should eq(64 * 1024 * 1024)
    end
  end
end
