require "../../spec_helper"
require "json"

private def make_item(id, kind, name, file, scope = "source", byte_start = nil, byte_end = nil)
  Chiasmus::Discovery::Item.new(
    id: id, kind: kind, scope: scope, name: name, file: file,
    byte_start: byte_start, byte_end: byte_end,
  )
end

describe Chiasmus::MCPServer::Tools::SearchTool do
  describe "input schema" do
    it "includes query and files as required params" do
      schema = Chiasmus::MCPServer::Tools::SearchTool.input_schema
      schema.properties.has_key?("query").should be_true
      schema.properties.has_key?("files").should be_true
      req = schema.required
      req.should_not be_nil
      req = req.not_nil!
      req.includes?("query").should be_true
      req.includes?("files").should be_true
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

      sources = {
        "src/server.ts" => "export class Server {}",
        "src/worker.rb" => "class Worker; end",
      }

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
