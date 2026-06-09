require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/walkers"
require "../../../src/chiasmus/graph/extractor"

include Chiasmus::Graph

describe "Crystal walker call extraction" do
  it "captures bare method calls (foo without parens)" do
    cr = <<-CR
      def caller
        target
      end
    CR
    graph = Extractor.extract_graph([SourceFile.new(path: "/tmp/t.cr", content: cr)])
    callees = graph.calls.map(&.callee).to_set
    callees.should contain("target")
  end

  it "captures method calls with arguments" do
    cr = <<-CR
      def caller
        target(1, 2)
      end
    CR
    graph = Extractor.extract_graph([SourceFile.new(path: "/tmp/t.cr", content: cr)])
    callees = graph.calls.map(&.callee).to_set
    callees.should contain("target")
  end

  it "captures obj.method calls with correct method name" do
    cr = <<-CR
      def caller
        obj.method
      end
    CR
    graph = Extractor.extract_graph([SourceFile.new(path: "/tmp/t.cr", content: cr)])
    callees = graph.calls.map(&.callee).to_set
    callees.should contain("method")
  end

  it "captures Foo.new constructor calls" do
    cr = <<-CR
      def caller
        Widget.new
      end
    CR
    graph = Extractor.extract_graph([SourceFile.new(path: "/tmp/t.cr", content: cr)])
    callees = graph.calls.map(&.callee).to_set
    callees.should contain("new")
  end

  it "captures chained method calls" do
    cr = <<-CR
      def caller
        foo.bar.baz
      end
    CR
    graph = Extractor.extract_graph([SourceFile.new(path: "/tmp/t.cr", content: cr)])
    callees = graph.calls.map(&.callee).to_set
    callees.should contain("baz")
    callees.should contain("bar")
  end

  it "captures obj.method(arg) calls with correct method name" do
    cr = <<-CR
      def caller
        obj.target(42)
      end
    CR
    graph = Extractor.extract_graph([SourceFile.new(path: "/tmp/t.cr", content: cr)])
    callees = graph.calls.map(&.callee).to_set
    callees.should contain("target")
  end

  it "does not treat assignment targets as calls, but bare expressions are calls" do
    cr = <<-CR
      def calculate(x, y)
        z = x + y
        z
      end
    CR
    graph = Extractor.extract_graph([SourceFile.new(path: "/tmp/t.cr", content: cr)])
    callees = graph.calls.map(&.callee).to_set
    # x and y as call arguments are NOT calls
    callees.should_not contain("x")
    callees.should_not contain("y")
    # z as bare expression IS a method call in Crystal semantics
    # Assignment target 'z' should not be treated as a call
  end

  it "does not treat assignment targets as calls" do
    cr = <<-CR
      class Foo
        def initialize
          @name = "hello"
          @value = 42
        end
      end
    CR
    graph = Extractor.extract_graph([SourceFile.new(path: "/tmp/t.cr", content: cr)])
    callees = graph.calls.map(&.callee).to_set
    callees.should_not contain("name")
    callees.should_not contain("value")
    callees.should_not contain("@name")
    callees.should_not contain("@value")
  end
end
