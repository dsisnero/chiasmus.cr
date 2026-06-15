require "../../spec_helper"
require "../../../src/chiasmus/mcp_server/tools/graph"
require "../../../src/chiasmus/mcp_server/types"
require "../../../src/chiasmus/graph/cache"
require "json"
require "file_utils"

describe "chiasmus_graph diff analysis via MCP" do
  it "GraphInput accepts against field for snapshot diff" do
    input = Chiasmus::MCPServer::Types::GraphInput.from_json({
      "files"    => ["/tmp/test.go"],
      "analysis" => "diff",
      "against"  => "my-snapshot",
    }.to_json)
    input.against.should eq("my-snapshot")
  end

  it "input schema includes against parameter" do
    schema = Chiasmus::MCPServer::Tools::GraphTool.input_schema
    schema.properties.has_key?("against").should be_true
  end

  it "returns diff results when against is specified with valid snapshot" do
    cache_dir = File.join(Dir.tempdir, "chiasmus-graph-diff-#{Random::Secure.hex(8)}")
    go_file = File.join(Dir.tempdir, "graph-diff-test.go")

    File.write(go_file, <<-GO)
      package main
      func original() {}
    GO

    graph_before = Chiasmus::Graph::CodeGraph.new(
      defines: [
        Chiasmus::Graph::DefinesFact.new(file: go_file, name: "original",
          kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
      ],
    )
    Chiasmus::Graph::GraphCache.save_snapshot("baseline", graph_before, cache_dir)

    tool = Chiasmus::MCPServer::Tools::GraphTool.new
    result = tool.invoke({
      "files"    => JSON::Any.new([JSON::Any.new(go_file)]),
      "analysis" => JSON::Any.new("diff"),
      "against"  => JSON::Any.new("baseline"),
      "cache"    => JSON.parse(%({"cache_dir": "#{cache_dir}"})),
    })

    result.status.should eq("success")
    g = result.as(Chiasmus::MCPServer::Types::GraphResponse)
    g.analysis.should eq("diff")
    g.result.to_s.should_not contain("not yet wired")

    File.delete(go_file)
    FileUtils.rm_rf(cache_dir)
  end

  it "GraphInput accepts save_snapshot field" do
    input = Chiasmus::MCPServer::Types::GraphInput.from_json({
      "files"         => ["/tmp/test.go"],
      "analysis"      => "summary",
      "save_snapshot" => "my-baseline",
    }.to_json)
    input.save_snapshot.should eq("my-baseline")
  end

  it "GraphInput accepts cache as GraphCacheOptions object" do
    input = Chiasmus::MCPServer::Types::GraphInput.from_json({
      "files"    => ["/tmp/test.go"],
      "analysis" => "summary",
      "cache"    => {"cache_dir" => "/tmp/cache", "repo_key" => "my-project"},
    }.to_json)
    input.cache.should_not be_nil
    opts = input.cache || raise("Expected cache")
    opts.cache_dir.should eq("/tmp/cache")
    opts.repo_key.should eq("my-project")
  end

  it "input schema includes save_snapshot parameter" do
    schema = Chiasmus::MCPServer::Tools::GraphTool.input_schema
    schema.properties.has_key?("save_snapshot").should be_true
  end

  it "input schema includes cache parameter" do
    schema = Chiasmus::MCPServer::Tools::GraphTool.input_schema
    schema.properties.has_key?("cache").should be_true
  end

  it "rejects same-name save_snapshot and against for diff analysis" do
    cache_dir = File.join(Dir.tempdir, "chiasmus-guard-#{Random::Secure.hex(8)}")
    go_file = File.join(Dir.tempdir, "guard-test.go")
    File.write(go_file, "package main\nfunc f() {}")

    tool = Chiasmus::MCPServer::Tools::GraphTool.new
    result = tool.invoke({
      "files"         => JSON::Any.new([JSON::Any.new(go_file)]),
      "analysis"      => JSON::Any.new("diff"),
      "against"       => JSON::Any.new("same-name"),
      "save_snapshot" => JSON::Any.new("same-name"),
      "cache"         => JSON.parse(%({"cache_dir": "#{cache_dir}"})),
    })

    result.status.should eq("success")
    g = result.as(Chiasmus::MCPServer::Types::GraphResponse)
    g.result.to_s.should contain("cannot name the same snapshot")

    File.delete(go_file)
    FileUtils.rm_rf(cache_dir)
  end

  it "saves snapshot when save_snapshot and cache are provided" do
    cache_dir = File.join(Dir.tempdir, "chiasmus-save-#{Random::Secure.hex(8)}")
    go_file = File.join(Dir.tempdir, "save-test.go")
    File.write(go_file, "package main\nfunc f() {}")

    tool = Chiasmus::MCPServer::Tools::GraphTool.new
    result = tool.invoke({
      "files"         => JSON::Any.new([JSON::Any.new(go_file)]),
      "analysis"      => JSON::Any.new("summary"),
      "save_snapshot" => JSON::Any.new("tool-saved"),
      "cache"         => JSON.parse(%({"cache_dir": "#{cache_dir}"})),
    })

    result.status.should eq("success")

    loaded = Chiasmus::Graph::GraphCache.load_snapshot("tool-saved", cache_dir)
    loaded.should_not be_nil
    (loaded || raise("Expected snapshot")).defines.map(&.name).should contain("f")

    File.delete(go_file)
    FileUtils.rm_rf(cache_dir)
  end

  it "GraphInput accepts include_insights field" do
    input = Chiasmus::MCPServer::Types::GraphInput.from_json({
      "files"            => ["/tmp/test.go"],
      "analysis"         => "facts",
      "include_insights" => true,
    }.to_json)
    input.include_insights.should be_true
  end

  it "input schema includes include_insights parameter" do
    schema = Chiasmus::MCPServer::Tools::GraphTool.input_schema
    schema.properties.has_key?("include_insights").should be_true
  end

  it "include_insights defaults to false" do
    input = Chiasmus::MCPServer::Types::GraphInput.from_json({
      "files"    => ["/tmp/test.go"],
      "analysis" => "facts",
    }.to_json)
    input.include_insights.should be_false
  end
end
