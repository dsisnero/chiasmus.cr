require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/walkers"
require "../../../src/chiasmus/graph/extractor"
require "../../../src/chiasmus/graph/analyses"

include Chiasmus::Graph

describe "Crystal walker call extraction" do
  it "keeps same-named methods in separate module and class scopes" do
    cr = <<-CR
      module Demo
        class Alpha
          def run
            helper
          end

          def helper
            run
          end
        end

        class Beta
          def run
            helper
          end

          def helper
          end
        end
      end
    CR

    graph = Extractor.extract_graph([SourceFile.new(path: "/tmp/scoped_methods.cr", content: cr)])

    graph.defines.compact_map(&.qualified_name).should contain("Demo.Alpha.run")
    graph.defines.compact_map(&.qualified_name).should contain("Demo.Beta.run")
    graph.calls.map { |fact| {fact.caller_qn, fact.callee_qn} }.should contain({"Demo.Alpha.run", "Demo.Alpha.helper"})
    graph.calls.map { |fact| {fact.caller_qn, fact.callee_qn} }.should contain({"Demo.Beta.run", "Demo.Beta.helper"})

    result = Analyses.run_analysis_from_graph(
      graph,
      AnalysisRequest.new(analysis: AnalysisType::Cycles)
    )
    result.result.as(Array(String)).to_set.should eq(Set{"Demo.Alpha.run", "Demo.Alpha.helper"})
  end

  it "does not treat local variables as function calls" do
    cr = <<-CR
      def calculate(x, y)
        result = x + y
        result
      end
    CR
    graph = Extractor.extract_graph([SourceFile.new(path: "/tmp/t.cr", content: cr)])
    graph.defines.map(&.name).should eq(["calculate"])
    graph.calls.map(&.callee).should_not contain("x")
    graph.calls.map(&.callee).should_not contain("y")
  end

  it "captures real method calls with arguments" do
    cr = <<-CR
      def foo
        bar(42)
        baz("hello")
      end
    CR
    graph = Extractor.extract_graph([SourceFile.new(path: "/tmp/t2.cr", content: cr)])
    graph.defines.map(&.name).should eq(["foo"])
    callees = graph.calls.map(&.callee).to_set
    callees.should contain("bar")
    callees.should contain("baz")
  end

  it "captures method calls on objects" do
    cr = <<-CR
      def process(list)
        list.push(1)
        list.sort
      end
    CR
    graph = Extractor.extract_graph([SourceFile.new(path: "/tmp/t3.cr", content: cr)])
    graph.defines.map(&.name).should eq(["process"])
    callees = graph.calls.map(&.callee).to_set
    callees.should contain("push")
  end

  it "does not treat assignment targets as calls" do
    cr = <<-CR
      class Foo
        def initialize(@name, @value)
        end
      end
    CR
    graph = Extractor.extract_graph([SourceFile.new(path: "/tmp/t4.cr", content: cr)])
    graph.defines.map(&.name).should contain("initialize")
    graph.calls.map(&.callee).should_not contain("@name")
    graph.calls.map(&.callee).should_not contain("@value")
    graph.calls.map(&.callee).should_not contain("name")
    graph.calls.map(&.callee).should_not contain("value")
  end
end

describe "Crystal walker structural extraction" do
  it "extracts class and struct definitions" do
    cr = <<-CR
      class Server
        def start; end
      end

      struct Point
        def initialize(@x : Int32, @y : Int32); end
      end
    CR
    graph = Extractor.extract_graph([SourceFile.new(path: "/tmp/struct.cr", content: cr)])
    names = graph.defines.map(&.name).to_set
    names.should contain("Server")
    names.should contain("Point")
  end

  it "extracts module definitions" do
    cr = <<-CR
      module Utils
        def self.helper
          puts("ok")
        end
      end
    CR
    graph = Extractor.extract_graph([SourceFile.new(path: "/tmp/mod.cr", content: cr)])
    names = graph.defines.map(&.name).to_set
    names.should contain("Utils")
    names.should contain("helper")
  end

  it "extracts enum definitions" do
    cr = <<-CR
      enum Color
        Red
        Green
        Blue
      end
    CR
    graph = Extractor.extract_graph([SourceFile.new(path: "/tmp/enum.cr", content: cr)])
    names = graph.defines.map(&.name).to_set
    names.should contain("Color")
  end

  it "extracts alias types" do
    cr = <<-CR
      alias StringOrNil = String | Nil
    CR
    graph = Extractor.extract_graph([SourceFile.new(path: "/tmp/alias.cr", content: cr)])
    names = graph.defines.map(&.name).to_set
    names.should contain("StringOrNil")
  end

  it "builds contains relationships for class methods" do
    cr = <<-CR
      class Calculator
        def add(a, b)
          a + b
        end

        def subtract(a, b)
          a - b
        end
      end
    CR
    graph = Extractor.extract_graph([SourceFile.new(path: "/tmp/contains.cr", content: cr)])
    parents = graph.contains.map(&.parent).to_set
    children = graph.contains.map(&.child).to_set
    parents.should contain("Calculator")
    children.should contain("add")
    children.should contain("subtract")
  end

  it "keeps generic class methods contained under the class instead of the outer module" do
    cr = <<-CR
      module Utils
        class Result(T)
          def initialize(@value : T? = nil)
          end
        end
      end
    CR
    graph = Extractor.extract_graph([SourceFile.new(path: "/tmp/generic_contains.cr", content: cr)])

    names = graph.defines.map(&.name).to_set
    names.should contain("Result")
    names.should contain("initialize")

    graph.contains.map { |fact| {fact.parent, fact.child} }.should contain({"Result", "initialize"})
    graph.contains.map { |fact| {fact.parent, fact.child} }.should_not contain({"Utils", "initialize"})
  end

  it "extracts crystal-native definitions for macros, constants, annotations, and lib bindings" do
    cr = <<-CR
      VERSION = "1.0.0"

      annotation Audited
      end

      macro define_reader(name)
        def {{name}}
        end
      end

      lib LibC
        fun malloc(size : UInt64) : Void*
        type Handle = Void*
        struct Point
          x : Int32
        end
      end
    CR
    graph = Extractor.extract_graph([SourceFile.new(path: "/tmp/crystal_defs.cr", content: cr)])

    definitions = graph.defines.map { |fact| {fact.kind, fact.name} }.to_set
    definitions.should contain({SymbolKind::Variable, "VERSION"})
    definitions.should contain({SymbolKind::Type, "Audited"})
    definitions.should contain({SymbolKind::Function, "define_reader"})
    definitions.should contain({SymbolKind::Module, "LibC"})
    definitions.should contain({SymbolKind::Function, "malloc"})
    definitions.should contain({SymbolKind::Type, "Handle"})
    definitions.should contain({SymbolKind::Class, "Point"})
  end

  it "does not record compile-time macro expressions as runtime calls" do
    cr = <<-CR
      module Crig
        {% begin %}
          {% version_line = read_file("#{__DIR__}/../shard.yml").lines.select(&.starts_with?("version:")).first %}
          VERSION = {{ version_line.split(":").last.strip }}
        {% end %}
      end
    CR

    graph = Extractor.extract_graph([SourceFile.new(path: "/tmp/crig_macro.cr", content: cr)])

    graph.defines.map(&.name).should contain("Crig")
    graph.defines.map(&.name).should contain("VERSION")
    graph.contains.map { |fact| {fact.parent, fact.child} }.should contain({"Crig", "VERSION"})
    graph.calls.should be_empty
  end

  it "keeps nested crystal-native definitions attached to their enclosing container" do
    cr = <<-CR
      module Outer
        VALUE = 1

        annotation Audited
        end

        alias Handle = String

        lib LibC
          type Token = Void*
          fun malloc(size : UInt64) : Void*
        end
      end
    CR
    graph = Extractor.extract_graph([SourceFile.new(path: "/tmp/crystal_nested_defs.cr", content: cr)])

    contains = graph.contains.map { |fact| {fact.parent, fact.child} }.to_set
    contains.should contain({"Outer", "VALUE"})
    contains.should contain({"Outer", "Audited"})
    contains.should contain({"Outer", "Handle"})
    contains.should contain({"Outer", "LibC"})
    contains.should contain({"LibC", "Token"})
    contains.should contain({"LibC", "malloc"})
  end

  it "extracts require imports" do
    cr = <<-CR
      require "./parser"
      require "../utils/config"

      def run; end
    CR
    graph = Extractor.extract_graph([SourceFile.new(path: "/tmp/imports.cr", content: cr)])
    sources = graph.imports.map(&.source)
    sources.should contain("./parser")
    sources.should contain("../utils/config")
  end

  it "extracts self.method as class method" do
    cr = <<-CR
      class Factory
        def self.create
          new
        end
      end
    CR
    graph = Extractor.extract_graph([SourceFile.new(path: "/tmp/selfmethod.cr", content: cr)])
    method_def = graph.defines.find { |defn| defn.name == "create" }
    method_def.should_not be_nil
    method_def.as(DefinesFact).kind.should eq(SymbolKind::Method)
  end

  it "sets file node language to crystal" do
    cr = "def hello; end"
    graph = Extractor.extract_graph([SourceFile.new(path: "/tmp/lang.cr", content: cr)])
    graph.files.should_not be_nil
    file_node = (graph.files || raise("nil")).first
    file_node.language.should eq("crystal")
  end
end

describe "Crystal walker MCP integration" do
  it "returns summary analysis for Crystal source via GraphTool" do
    cr = <<-CR
      class Router
        def handle(req)
          validate(req)
          process(req)
        end

        def validate(req); end
        def process(req); end
      end

      def main
        router = Router.new
        router.handle("GET /")
      end
    CR
    tmpdir = Dir.tempdir
    file_path = File.join(tmpdir, "crystal_graph_test.cr")
    File.write(file_path, cr)

    begin
      tool = Chiasmus::MCPServer::Tools::GraphTool.new
      result = tool.invoke({
        "files"    => JSON.parse([file_path].to_json),
        "analysis" => JSON::Any.new("summary"),
      })

      result.status.should eq("success")
      resp = result.as(Chiasmus::MCPServer::Types::GraphResponse)
      resp.analysis.should eq("summary")
    ensure
      File.delete(file_path) if File.exists?(file_path)
    end
  end

  it "finds callers of a Crystal function via GraphTool" do
    cr = <<-CR
      def helper; end
      def caller_a
        helper()
      end
      def caller_b
        helper()
      end
    CR
    tmpdir = Dir.tempdir
    file_path = File.join(tmpdir, "crystal_callers_test.cr")
    File.write(file_path, cr)

    begin
      tool = Chiasmus::MCPServer::Tools::GraphTool.new
      result = tool.invoke({
        "files"    => JSON.parse([file_path].to_json),
        "analysis" => JSON::Any.new("callers"),
        "target"   => JSON::Any.new("helper"),
      })

      result.status.should eq("success")
    ensure
      File.delete(file_path) if File.exists?(file_path)
    end
  end

  it "generates Prolog facts from Crystal source" do
    cr = <<-CR
      require "./utils"

      class Server
        def start
          listen()
        end

        def listen; end
      end
    CR
    tmpdir = Dir.tempdir
    file_path = File.join(tmpdir, "crystal_facts_test.cr")
    File.write(file_path, cr)

    begin
      tool = Chiasmus::MCPServer::Tools::GraphTool.new
      result = tool.invoke({
        "files"    => JSON.parse([file_path].to_json),
        "analysis" => JSON::Any.new("facts"),
      })

      result.status.should eq("success")
      facts = result.as(Chiasmus::MCPServer::Types::GraphResponse).result.to_s
      facts.should contain("defines")
      facts.should contain("Server")
    ensure
      File.delete(file_path) if File.exists?(file_path)
    end
  end

  it "builds codebase map from Crystal source via MapTool" do
    cr = <<-CR
      module Graph
        class Extractor
          def extract(files)
            parse(files)
          end

          def parse(files); end
        end
      end
    CR
    tmpdir = Dir.tempdir
    file_path = File.join(tmpdir, "crystal_map_test.cr")
    File.write(file_path, cr)

    begin
      tool = Chiasmus::MCPServer::Tools::MapTool.new
      result = tool.invoke({
        "files" => JSON.parse([file_path].to_json),
      })

      result.status.should eq("success")
    ensure
      File.delete(file_path) if File.exists?(file_path)
    end
  end

  it "uses async graph extraction inside MapTool" do
    cr = <<-CR
      class AsyncMap
        def build
        end
      end
    CR
    tmpdir = Dir.tempdir
    file_path = File.join(tmpdir, "crystal_map_async_test.cr")
    File.write(file_path, cr)
    entered = Channel(Bool).new(1)
    release = Channel(Bool).new(1)
    result_chan = Channel(Chiasmus::MCPServer::Types::Response).new(1)

    Chiasmus::Graph::Extractor.set_before_async_result_send_hook_for_test do
      entered.send(true)
      release.receive?
    end

    begin
      tool = Chiasmus::MCPServer::Tools::MapTool.new
      spawn do
        result_chan.send(tool.invoke({
          "files" => JSON.parse([file_path].to_json),
        }))
      end

      TreeSitterManager::Timeout.with_timeout_async(250, entered).should eq(true)

      select
      when result_chan.receive?
        fail("expected MapTool to remain blocked on async extraction result")
      else
      end

      release.send(true)
      result = TreeSitterManager::Timeout.with_timeout_async(250, result_chan)
      result.should_not be_nil
      graph_result = result || raise "expected async walker result"
      graph_result.status.should eq("success")
    ensure
      Chiasmus::Graph::Extractor.clear_before_async_result_send_hook_for_test
      File.delete(file_path) if File.exists?(file_path)
    end
  end

  it "generates review plan for Crystal source via ReviewTool" do
    cr = <<-CR
      class Handler
        def handle(req)
          validate(req)
          process(req)
        end
      end
    CR
    tmpdir = Dir.tempdir
    file_path = File.join(tmpdir, "crystal_review_test.cr")
    File.write(file_path, cr)

    begin
      tool = Chiasmus::MCPServer::Tools::ReviewTool.new
      result = tool.invoke({
        "files" => JSON.parse([file_path].to_json),
      })

      result.status.should eq("success")
    ensure
      File.delete(file_path) if File.exists?(file_path)
    end
  end
end

describe "Crystal concurrent extraction" do
  it "extracts multiple Crystal files concurrently" do
    files = (1..8).map do |i|
      cr = <<-CR
        class Worker#{i}
          def run
            process_#{i}()
          end

          def process_#{i}; end
        end
      CR
      SourceFile.new(path: "/tmp/worker#{i}.cr", content: cr)
    end

    graph = Extractor.extract_graph(files)

    names = graph.defines.map(&.name).to_set
    (1..8).each do |i|
      names.should contain("Worker#{i}")
    end

    graph.files.should_not be_nil
    (graph.files || raise("nil")).size.should eq(8)
    (graph.files || raise("nil")).each do |file_node|
      file_node.language.should eq("crystal")
    end
  end

  it "extracts mixed Crystal and Go files concurrently" do
    cr_file = SourceFile.new(
      path: "/tmp/mixed.cr",
      content: "class CrystalClass\n  def crmethod; end\nend\n"
    )
    go_file = SourceFile.new(
      path: "/tmp/mixed.go",
      content: "package main\nfunc GoFunc() {}\n"
    )

    graph = Extractor.extract_graph([cr_file, go_file])

    names = graph.defines.map(&.name).to_set
    names.should contain("CrystalClass")
    names.should contain("GoFunc")

    graph.files.should_not be_nil
    langs = (graph.files || raise("nil")).map(&.language).to_set
    langs.should contain("crystal")
    langs.should contain("go")
  end
end
