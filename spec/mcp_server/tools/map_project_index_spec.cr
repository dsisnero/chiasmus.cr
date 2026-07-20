require "../../spec_helper"
require "file_utils"
require "tree-sitter-manager"

describe Chiasmus::MCPServer::Tools::MapTool do
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
