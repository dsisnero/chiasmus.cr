require "../../spec_helper"
require "file_utils"
require "tree-sitter-manager"

describe Chiasmus::MCPServer::Tools::MapTool do
  it "applies overview include globs from tool arguments" do
    dir = File.join(Dir.tempdir, "map-include-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    crystal_path = File.join(dir, "selected.cr")
    go_path = File.join(dir, "ignored.go")
    File.write(crystal_path, "module Selected\n  def self.call\n  end\nend\n")
    File.write(go_path, "package ignored\nfunc Call() {}\n")

    begin
      response = Chiasmus::MCPServer::Tools::MapTool.new.invoke({
        "files"       => JSON.parse([crystal_path, go_path].to_json),
        "mode"        => JSON::Any.new("overview"),
        "format"      => JSON::Any.new("json"),
        "include"     => JSON.parse(["**/*.cr"].to_json),
        "max_exports" => JSON::Any.new(-1_i64),
        "cache"       => JSON::Any.new(File.join(dir, "cache")),
      })
      payload = JSON.parse(response.to_json)

      payload["kind"].as_s.should eq("overview")
      payload["summary"]["files"].as_i.should eq(1)
      payload["summary"]["languages"].as_a.map(&.as_s).should eq(["crystal"])
    ensure
      Chiasmus::Graph::GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(dir)
    end
  end

  it "refreshes requested files through the project index without full graph extraction" do
    dir = File.join(Dir.tempdir, "map-project-index-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    path = File.join(dir, "sample.cr")
    File.write(path, "class Sample\n  def call\n  end\nend\n")

    entered = Channel(Bool).new(1)
    release = Channel(Bool).new(1)
    result_chan = Channel(Chiasmus::MCPServer::Types::Response).new(1)
    index = Chiasmus::Index::ProjectIndex.new

    Chiasmus::Graph::Extractor.set_before_async_result_send_hook_for_test do
      entered.send(true)
      release.receive?
    end

    begin
      tool = Chiasmus::MCPServer::Tools::MapTool.new(index)
      spawn do
        result_chan.send(tool.invoke({
          "files" => JSON.parse([path].to_json),
          "mode"  => JSON::Any.new("file"),
          "path"  => JSON::Any.new(path),
        }))
      end

      result = TreeSitterManager::Timeout.with_timeout_async(250, result_chan)
      result.should_not be_nil
      result.not_nil!.status.should eq("success")

      select
      when entered.receive?
        fail("expected MapTool to avoid full-graph async extraction when project index is available")
      else
      end
    ensure
      release.send(true) rescue nil
      Chiasmus::Graph::Extractor.clear_before_async_result_send_hook_for_test
      index.close
      FileUtils.rm_rf(dir)
    end
  end
end
