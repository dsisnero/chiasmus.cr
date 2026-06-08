require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/walkers"
require "../../../src/chiasmus/graph/extractor"

include Chiasmus::Graph

describe "Crystal walker call extraction" do
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
    graph.calls.map(&.callee).should_not contain("result")
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
    # sort is a no-arg call - may or may not be detected
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
    # @name and @value are instance var assignments, not calls
    graph.calls.map(&.callee).should_not contain("@name")
    graph.calls.map(&.callee).should_not contain("@value")
    graph.calls.map(&.callee).should_not contain("name")
    graph.calls.map(&.callee).should_not contain("value")
  end
end
