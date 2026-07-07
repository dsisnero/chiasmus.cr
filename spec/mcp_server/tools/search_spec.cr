require "../../spec_helper"
require "json"
require "file_utils"
require "tree-sitter-manager"

class Chiasmus::MCPServer::Tools::SearchTool
  def read_search_files_for_test(files : Array(String), max_concurrent : Int32 = DEFAULT_MAX_CONCURRENT, &reader : String -> String)
    read_search_files(files, max_concurrent, &reader)
  end
end

private def make_item(id, kind, name, file, scope = "source", byte_start = nil, byte_end = nil)
  Chiasmus::Discovery::Item.new(
    id: id, kind: kind, scope: scope, name: name, file: file,
    byte_start: byte_start, byte_end: byte_end,
  )
end

describe Chiasmus::MCPServer::Tools::SearchTool do
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

  describe "CodeIndex integration via Discovery pipeline" do
    it "builds a CodeIndex from TypeScript source using Discovery items" do
      items = [
        make_item("src/app.ts::class::MyService", "class", "MyService", "src/app.ts"),
        make_item("src/app.ts::function::handleRequest", "function", "handleRequest", "src/app.ts"),
        make_item("src/app.ts::function::validate", "function", "validate", "src/app.ts"),
      ]

      sources = {
        "src/app.ts" => "export class MyService { handle() {} }\nexport function handleRequest() { validate() }\nexport function validate() {}",
      }

      index = Chiasmus::Search::CodeIndex.for_language("typescript")
        .with_config(Chiasmus::Search::CodeIndexConfig.defaults_for("typescript"))
        .from_items(items, sources)
        .build

      index.count.should eq(3)
      index.language.should eq("typescript")
    end

    it "filters items by configured kinds (e.g. only classes)" do
      items = [
        make_item("src/app.ts::class::MyService", "class", "MyService", "src/app.ts"),
        make_item("src/app.ts::function::doStuff", "function", "doStuff", "src/app.ts"),
      ]

      sources = {
        "src/app.ts" => "export class MyService {}\nexport function doStuff() {}",
      }

      config = Chiasmus::Search::CodeIndexConfig.new(indexed_kinds: ["class"].to_set)
      index = Chiasmus::Search::CodeIndex.for_language("typescript")
        .with_config(config)
        .from_items(items, sources)
        .build

      index.count.should eq(1)
      index.documents[0].name.should eq("MyService")
    end

    it "supports multi-language search via separate CodeIndex instances" do
      ts_items = [
        make_item("src/server.ts::class::Server", "class", "Server", "src/server.ts"),
      ]
      py_items = [
        make_item("src/utils.py::function::helper", "function", "helper", "src/utils.py"),
      ]

      ts_sources = {"src/server.ts" => "export class Server { start() {} }"}
      py_sources = {"src/utils.py" => "def helper(): pass"}

      ts_index = Chiasmus::Search::CodeIndex.for_language("typescript")
        .from_items(ts_items, ts_sources).build
      py_index = Chiasmus::Search::CodeIndex.for_language("python")
        .from_items(py_items, py_sources).build

      ts_results = ts_index.search("server")
      py_results = py_index.search("helper")

      ts_results.size.should eq(1)
      ts_results[0].document.name.should eq("Server")
      py_results.size.should eq(1)
      py_results[0].document.name.should eq("helper")
    end

    it "respects languages filter to only process specified languages" do
      ts_items = [
        make_item("src/server.ts::class::Server", "class", "Server", "src/server.ts"),
      ]
      ruby_items = [
        make_item("src/worker.rb::class::Worker", "class", "Worker", "src/worker.rb"),
      ]

      # Only build index for TypeScript
      filter_langs = ["typescript"].to_set

      all_items = ts_items + ruby_items
      filtered = all_items.select { |item|
        lang = File.extname(item.file) == ".ts" ? "typescript" : "ruby"
        filter_langs.includes?(lang)
      }

      filtered.size.should eq(1)
      filtered[0].name.should eq("Server")
    end
  end
end
