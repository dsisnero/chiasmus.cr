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
      DefinesFact.new(file: "a.go", name: "foo", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1)),
    ])
    graph_after = CodeGraph.new(defines: [
      DefinesFact.new(file: "a.go", name: "foo", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1)),
      DefinesFact.new(file: "b.go", name: "baz", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1)),
    ])
    result = GraphDiffer.diff(graph_before, graph_after)
    result.added_nodes.should contain("baz")
  end

  it "detects removed nodes via GraphDiffer.diff" do
    graph_before = CodeGraph.new(defines: [
      DefinesFact.new(file: "a.go", name: "oldFunc", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1)),
      DefinesFact.new(file: "a.go", name: "kept", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(5)),
    ])
    graph_after = CodeGraph.new(defines: [
      DefinesFact.new(file: "a.go", name: "kept", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(5)),
    ])
    result = GraphDiffer.diff(graph_before, graph_after)
    result.removed_nodes.should contain("oldFunc")
  end

  it "round-trips snapshot through GraphCache" do
    cache_dir = File.join(Dir.tempdir, "chiasmus-diff-#{Random::Secure.hex(8)}")
    graph = CodeGraph.new(
      defines: [DefinesFact.new(file: "a.go", name: "hello", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1))],
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
      defines: [DefinesFact.new(file: "a.go", name: "foo", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1))],
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

  describe "snapshot lifecycle" do
    it "list_snapshots returns saved snapshot names" do
      cache_dir = File.join(Dir.tempdir, "chiasmus-list-#{Random::Secure.hex(8)}")
      graph = CodeGraph.new(
        defines: [DefinesFact.new(file: "a.go", name: "f", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1))],
      )
      GraphCache.save_snapshot("snap1", graph, cache_dir)
      GraphCache.save_snapshot("snap2", graph, cache_dir)

      names = GraphCache.list_snapshots(cache_dir)
      names.sort.should eq(["snap1", "snap2"])
      FileUtils.rm_rf(cache_dir)
    end

    it "list_snapshots returns empty array for nonexistent directory" do
      cache_dir = File.join(Dir.tempdir, "chiasmus-empty-#{Random::Secure.hex(8)}")
      names = GraphCache.list_snapshots(cache_dir)
      names.should be_empty
    end

    it "delete_snapshot removes a saved snapshot" do
      cache_dir = File.join(Dir.tempdir, "chiasmus-del-#{Random::Secure.hex(8)}")
      graph = CodeGraph.new(
        defines: [DefinesFact.new(file: "a.go", name: "f", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1))],
      )
      GraphCache.save_snapshot("temp", graph, cache_dir)

      loaded_before = GraphCache.load_snapshot("temp", cache_dir)
      loaded_before.should_not be_nil

      GraphCache.delete_snapshot("temp", cache_dir)
      loaded_after = GraphCache.load_snapshot("temp", cache_dir)
      loaded_after.should be_nil
      FileUtils.rm_rf(cache_dir)
    end

    it "delete_snapshot is a no-op for nonexistent snapshot" do
      cache_dir = File.join(Dir.tempdir, "chiasmus-delnoop-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(cache_dir)
      GraphCache.delete_snapshot("nonexistent", cache_dir)
      FileUtils.rm_rf(cache_dir)
    end

    it "clear_repo_cache removes all snapshots" do
      cache_dir = File.join(Dir.tempdir, "chiasmus-clear-#{Random::Secure.hex(8)}")
      graph = CodeGraph.new(
        defines: [DefinesFact.new(file: "a.go", name: "f", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1))],
      )
      GraphCache.save_snapshot("s1", graph, cache_dir)
      GraphCache.save_snapshot("s2", graph, cache_dir)

      GraphCache.clear_repo_cache(cache_dir)
      loaded = GraphCache.load_snapshot("s1", cache_dir)
      loaded.should be_nil
      FileUtils.rm_rf(cache_dir)
    end
  end
end
