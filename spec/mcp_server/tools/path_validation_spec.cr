require "../../spec_helper"
require "file_utils"

private def with_temp_repo_fixture(& : String ->)
  dir = File.tempname("chiasmus-path-validation-")
  Dir.mkdir(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir) rescue nil
  end
end

describe "MCP tool path validation" do
  it "graph tool rejects directory entries in files with a clear error" do
    with_temp_repo_fixture do |dir|
      result = Chiasmus::MCPServer::Tools::GraphTool.new.invoke({
        "files"    => JSON.parse([dir].to_json),
        "analysis" => JSON::Any.new("summary"),
      })

      result.status.should eq("error")
      error = result.as(Chiasmus::MCPServer::Types::ErrorResponse).error
      error.should contain("directories")
      error.should contain("source file paths")
    end
  end

  it "map tool rejects directory entries in files with a clear error" do
    with_temp_repo_fixture do |dir|
      result = Chiasmus::MCPServer::Tools::MapTool.new.invoke({
        "files" => JSON.parse([dir].to_json),
        "mode"  => JSON::Any.new("overview"),
      })

      result.status.should eq("error")
      error = result.as(Chiasmus::MCPServer::Types::ErrorResponse).error
      error.should contain("directories")
      error.should contain("source file paths")
    end
  end

  it "graph tool falls back to uncached extraction when cache_dir is unusable" do
    with_temp_repo_fixture do |dir|
      source_path = File.join(dir, "main.go")
      cache_path = File.join(dir, "cache-file")
      File.write(source_path, "package main\nfunc main() { helper() }\nfunc helper() {}\n")
      File.write(cache_path, "not-a-directory")

      result = Chiasmus::MCPServer::Tools::GraphTool.new.invoke({
        "files"    => JSON.parse([source_path].to_json),
        "analysis" => JSON::Any.new("summary"),
        "cache"    => JSON.parse(%({"cache_dir":"#{cache_path}"})),
      })

      result.status.should eq("success")
      result.as(Chiasmus::MCPServer::Types::GraphResponse).analysis.should eq("summary")
    end
  end

  it "map tool falls back to uncached extraction when cache_dir is unusable" do
    with_temp_repo_fixture do |dir|
      source_path = File.join(dir, "main.go")
      cache_path = File.join(dir, "cache-file")
      File.write(source_path, "package main\nfunc main() { helper() }\nfunc helper() {}\n")
      File.write(cache_path, "not-a-directory")

      result = Chiasmus::MCPServer::Tools::MapTool.new.invoke({
        "files" => JSON.parse([source_path].to_json),
        "mode"  => JSON::Any.new("overview"),
        "cache" => JSON::Any.new(cache_path),
      })

      result.status.should eq("success")
      result.as(Chiasmus::MCPServer::Types::MapResponse).content.should contain("# Codebase Overview")
    end
  end
end
