require "../../spec_helper"
require "file_utils"
require "tree-sitter-manager"

describe Chiasmus::MCPServer::Tools::ReadSymbolTool do
  it "returns source content and span for file plus name" do
    dir = File.join(Dir.tempdir, "read-symbol-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    path = File.join(dir, "sample.cr")
    File.write(path, "class Sample\n  def call(name)\n    puts name\n  end\nend\n")

    begin
      tool = Chiasmus::MCPServer::Tools::ReadSymbolTool.new
      result = tool.invoke({
        "files" => JSON.parse([path].to_json),
        "file"  => JSON::Any.new(path),
        "name"  => JSON::Any.new("call"),
      })

      result.status.should eq("success")
      symbol = result.as(Chiasmus::MCPServer::Types::ReadSymbolResponse)
      symbol.file.should eq(path)
      symbol.start_line.should eq(2)
      symbol.end_line.should eq(4)
      symbol.content.should contain("def call(name)")
      symbol.content.should contain("puts name")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "resolves by qualified_name when available" do
    dir = File.join(Dir.tempdir, "read-symbol-qn-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    path = File.join(dir, "sample.cr")
    File.write(path, "class Sample\n  def call(name)\n    puts name\n  end\nend\n")

    begin
      tool = Chiasmus::MCPServer::Tools::ReadSymbolTool.new
      result = tool.invoke({
        "files"          => JSON.parse([path].to_json),
        "qualified_name" => JSON::Any.new("Sample.call"),
      })

      result.status.should eq("success")
      symbol = result.as(Chiasmus::MCPServer::Types::ReadSymbolResponse)
      symbol.qualified_name.should eq("Sample.call")
      symbol.content.should contain("def call(name)")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "errors on ambiguous unqualified matches" do
    dir = File.join(Dir.tempdir, "read-symbol-ambiguous-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    a_path = File.join(dir, "a.cr")
    b_path = File.join(dir, "b.cr")
    File.write(a_path, "class Alpha\n  def call\n  end\nend\n")
    File.write(b_path, "class Beta\n  def call\n  end\nend\n")

    begin
      tool = Chiasmus::MCPServer::Tools::ReadSymbolTool.new
      result = tool.invoke({
        "files" => JSON.parse([a_path, b_path].to_json),
        "name"  => JSON::Any.new("call"),
      })

      result.status.should eq("error")
      result.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("Ambiguous")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "uses the project index refresh path instead of full graph extraction" do
    dir = File.join(Dir.tempdir, "read-symbol-project-index-#{Random::Secure.hex(8)}")
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
      tool = Chiasmus::MCPServer::Tools::ReadSymbolTool.new(index)
      spawn do
        result_chan.send(tool.invoke({
          "files" => JSON.parse([path].to_json),
          "file"  => JSON::Any.new(path),
          "name"  => JSON::Any.new("call"),
        }))
      end

      result = TreeSitterManager::Timeout.with_timeout_async(250, result_chan)
      result.should_not be_nil
      result.not_nil!.status.should eq("success")

      select
      when entered.receive?
        fail("expected ReadSymbolTool to avoid full-graph async extraction when project index is available")
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
