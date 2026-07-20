require "../../spec_helper"
require "json"
require "file_utils"
require "tree-sitter-manager"

class Chiasmus::MCPServer::Tools::SearchTool
  def read_search_files_for_test(files : Array(String), max_concurrent : Int32 = DEFAULT_MAX_CONCURRENT, &reader : String -> String)
    read_search_files(files, max_concurrent, &reader)
  end
end

private def make_item(id, kind, name, file, scope = "source", span = nil)
  Chiasmus::Discovery::Item.new(
    id: id, kind: kind, scope: scope, name: name, file: file,
    span: span,
  )
end

describe Chiasmus::MCPServer::Tools::SearchTool do
  describe "search hit serialization" do
    it "includes line_end when present" do
      hit = Chiasmus::MCPServer::Types::SearchHitJSON.new(
        name: "call",
        file: "src/app.cr",
        line: 10,
        line_end: 13,
        score: 0.91
      )

      payload = JSON.parse(hit.to_json)
      payload["line"].as_i.should eq(10)
      payload["line_end"].as_i.should eq(13)
    end
  end

  describe "file preparation" do
    it "reads files with bounded concurrency" do
      tmpdir = File.join(Dir.tempdir, "search-tool-files-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(tmpdir)

      paths = 6.times.map do |i|
        path = File.join(tmpdir, "f#{i}.ts")
        File.write(path, "export function f#{i}() {}")
        path
      end.to_a

      active = 0
      peak = 0
      mutex = Mutex.new

      begin
        tool = Chiasmus::MCPServer::Tools::SearchTool.new
        files, warnings = tool.read_search_files_for_test(paths, 2) do |path|
          mutex.synchronize do
            active += 1
            peak = {peak, active}.max
          end

          sleep 20.milliseconds
          File.read(path)
        ensure
          mutex.synchronize do
            active -= 1
          end
        end

        files.size.should eq(6)
        warnings.should be_empty
        peak.should be <= 2
      ensure
        FileUtils.rm_rf(tmpdir)
      end
    end
  end

  describe "graph extraction boundary" do
    it "uses async graph extraction before continuing to embedding resolution" do
      tmpdir = File.join(Dir.tempdir, "search-tool-async-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(tmpdir)
      path = File.join(tmpdir, "f.ts")
      File.write(path, "export function f() {}")
      entered = Channel(Bool).new(1)
      release = Channel(Bool).new(1)
      result_chan = Channel(Chiasmus::MCPServer::Types::Response).new(1)

      Chiasmus::Graph::Extractor.set_before_async_result_send_hook_for_test do
        entered.send(true)
        release.receive?
      end

      begin
        tool = Chiasmus::MCPServer::Tools::SearchTool.new
        spawn do
          with_env({
            "CHIASMUS_EMBED_PROVIDER" => "deepseek",
            "DEEPSEEK_API_KEY"        => nil,
            "OPENAI_API_KEY"          => nil,
          }) do
            result_chan.send(tool.invoke({
              "query" => JSON::Any.new("find function"),
              "files" => JSON.parse([path].to_json),
            }))
          end
        end

        TreeSitterManager::Timeout.with_timeout_async(250, entered).should eq(true)

        select
        when result_chan.receive?
          fail("expected SearchTool to remain blocked on async extraction result")
        else
        end

        release.send(true)
        result = TreeSitterManager::Timeout.with_timeout_async(250, result_chan)
        result.should_not be_nil
        search_result = result || raise "expected search tool result"
        search_result.status.should eq("error")
      ensure
        Chiasmus::Graph::Extractor.clear_before_async_result_send_hook_for_test
        FileUtils.rm_rf(tmpdir)
      end
    end
  end

  describe "input schema" do
    it "includes query and files as required params" do
      schema = Chiasmus::MCPServer::Tools::SearchTool.input_schema
      schema.properties.has_key?("query").should be_true
      schema.properties.has_key?("files").should be_true
      req = schema.required
      req.should_not be_nil
      if r = req
        r.includes?("query").should be_true
        r.includes?("files").should be_true
      end
    end

    it "includes languages filter param" do
      schema = Chiasmus::MCPServer::Tools::SearchTool.input_schema
      schema.properties.has_key?("languages").should be_true
      schema.properties["languages"]["type"].as_s.should eq("array")
    end

    it "includes kinds filter param" do
      schema = Chiasmus::MCPServer::Tools::SearchTool.input_schema
      schema.properties.has_key?("kinds").should be_true
      schema.properties["kinds"]["type"].as_s.should eq("array")
    end
  end
end
