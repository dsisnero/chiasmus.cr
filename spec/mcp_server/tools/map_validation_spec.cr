require "../../spec_helper"

private def map_validation_response(arguments : Hash(String, JSON::Any))
  Chiasmus::MCPServer::Tools::MapTool.new.invoke(arguments)
    .as(Chiasmus::MCPServer::Types::ErrorResponse)
end

describe Chiasmus::MCPServer::Tools::MapTool do
  it "rejects an unknown mode before indexing files" do
    response = map_validation_response({
      "files" => JSON.parse(["/not/a/real/file.cr"].to_json),
      "mode"  => JSON::Any.new("nonsense"),
    })

    response.error.should eq("Unknown mode: nonsense. Use 'overview', 'file', or 'symbol'.")
  end

  it "rejects an unknown format before indexing files" do
    response = map_validation_response({
      "files"  => JSON.parse(["/not/a/real/file.cr"].to_json),
      "format" => JSON::Any.new("raw"),
    })

    response.error.should eq("Unknown format: raw. Use 'markdown' or 'json'.")
  end

  it "reports the required file-mode path before indexing files" do
    response = map_validation_response({
      "files" => JSON.parse(["/not/a/real/file.cr"].to_json),
      "mode"  => JSON::Any.new("file"),
    })

    response.error.should eq("mode='file' requires 'path' (absolute file path)")
  end

  it "reports the required symbol-mode name before indexing files" do
    response = map_validation_response({
      "files" => JSON.parse(["/not/a/real/file.cr"].to_json),
      "mode"  => JSON::Any.new("symbol"),
    })

    response.error.should eq("mode='symbol' requires 'name' (symbol identifier)")
  end

  it "advertises the accepted mode and format values" do
    properties = Chiasmus::MCPServer::Tools::MapTool.input_schema.properties

    properties["mode"]["enum"].as_a.map(&.as_s).should eq(["overview", "file", "symbol"])
    properties["format"]["enum"].as_a.map(&.as_s).should eq(["markdown", "json"])
  end

  it "accepts the upstream boolean cache option and advertises it as boolean" do
    input = Chiasmus::MCPServer::Types::MapInput.from_json(%({"files":[],"cache":true}))
    properties = Chiasmus::MCPServer::Tools::MapTool.input_schema.properties

    input.cache.should eq(true)
    properties["cache"]["type"].as_s.should eq("boolean")
  end

  it "enables persistent cache only when cache is true" do
    resolver = Chiasmus::MCPServer::Tools::MapTool

    resolver.cache_dir_for(nil).should be_nil
    resolver.cache_dir_for(false).should be_nil
    resolver.cache_dir_for(true).should eq(Chiasmus::Graph::GraphCache.default_cache_dir)
    resolver.cache_dir_for("/tmp/map-cache").should eq("/tmp/map-cache")
  end
end
