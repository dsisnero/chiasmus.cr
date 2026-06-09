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
      "cache"    => JSON::Any.new(cache_dir),
    })

    result.status.should eq("success")
    g = result.as(Chiasmus::MCPServer::Types::GraphResponse)
    g.analysis.should eq("diff")
    g.result.to_s.should_not contain("not yet wired")

    File.delete(go_file)
    FileUtils.rm_rf(cache_dir)
  end
end
