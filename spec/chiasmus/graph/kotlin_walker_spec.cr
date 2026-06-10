require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/walkers"
require "../../../src/chiasmus/graph/extractor"

include Chiasmus::Graph

describe "Kotlin graph walker" do
  it "extracts class declarations" do
    code = <<-KT
      class Calculator {
        fun add(a: Int, b: Int): Int {
          return a + b
        }
      }
    KT
    sources = [SourceFile.new(path: "/tmp/t.kt", content: code)]
    graph = Extractor.extract_graph(sources)
    names = graph.defines.map(&.name).to_set
    names.should contain("Calculator")
    names.should contain("add")
  end

  it "extracts top-level function declarations" do
    code = <<-KT
      fun greet(name: String): String {
        return "Hello, $name"
      }
    KT
    sources = [SourceFile.new(path: "/tmp/t.kt", content: code)]
    graph = Extractor.extract_graph(sources)
    graph.defines.map(&.name).should contain("greet")
  end

  it "captures call expressions" do
    code = <<-KT
      fun helper() {}
      fun caller() {
        helper()
      }
    KT
    sources = [SourceFile.new(path: "/tmp/t.kt", content: code)]
    graph = Extractor.extract_graph(sources)
    callees = graph.calls.map(&.callee).to_set
    callees.should contain("helper")
  end

  it "captures import headers" do
    code = <<-KT
      import kotlin.math.max
      import java.util.List
      fun main() {}
    KT
    sources = [SourceFile.new(path: "/tmp/t.kt", content: code)]
    graph = Extractor.extract_graph(sources)
    graph.imports.size.should be >= 2
  end

  it "produces file nodes for Kotlin files" do
    code = "fun main() {}"
    sources = [SourceFile.new(path: "/tmp/t.kt", content: code)]
    graph = Extractor.extract_graph(sources)
    graph.files.should_not be_nil
    (graph.files || raise("nil")).first.language.should eq("kotlin")
  end
end
