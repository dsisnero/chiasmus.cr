require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/walkers"
require "../../../src/chiasmus/graph/extractor"
require "tree-sitter-manager"

include Chiasmus::Graph

describe "Scala graph walker" do
  if TreeSitterManager::GrammarLoader.tree_sitter_available?("scala")
    it "extracts class, object, and trait definitions" do
      code = <<-SCALA
        class Calculator {
          def add(a: Int, b: Int): Int = a + b
        }
        object Helper {
          val name = "helper"
        }
        trait Service {
          def handle(): Unit
        }
      SCALA
      sources = [SourceFile.new(path: "/tmp/t.scala", content: code)]
      graph = Extractor.extract_graph(sources)
      names = graph.defines.map(&.name).to_set
      names.should contain("Calculator")
      names.should contain("Helper")
      names.should contain("Service")
    end

    it "extracts function and variable definitions" do
      code = <<-SCALA
        def max(a: Int, b: Int): Int = if (a > b) a else b
        val greeting: String = "hello"
        var counter: Int = 0
      SCALA
      sources = [SourceFile.new(path: "/tmp/t.scala", content: code)]
      graph = Extractor.extract_graph(sources)
      names = graph.defines.map(&.name).to_set
      names.should contain("max")
      names.should contain("greeting")
      names.should contain("counter")
    end

    it "captures call expressions" do
      code = <<-SCALA
        def helper(): Unit = {}
        def caller(): Unit = {
          helper()
        }
      SCALA
      sources = [SourceFile.new(path: "/tmp/t.scala", content: code)]
      graph = Extractor.extract_graph(sources)
      callees = graph.calls.map(&.callee).to_set
      callees.should contain("helper")
    end

    it "captures import declarations" do
      code = <<-SCALA
        import scala.math.max
        import java.util.List
        object Main {}
      SCALA
      sources = [SourceFile.new(path: "/tmp/t.scala", content: code)]
      graph = Extractor.extract_graph(sources)
      graph.imports.size.should be >= 2
    end

    it "produces file nodes for Scala files" do
      code = "object Main { def main(args: Array[String]): Unit = {} }"
      sources = [SourceFile.new(path: "/tmp/t.scala", content: code)]
      graph = Extractor.extract_graph(sources)
      graph.files.should_not be_nil
      (graph.files || raise("nil")).first.language.should eq("scala")
    end
  else
    pending "extracts class, object, and trait definitions (scala grammar not available)"
    pending "extracts function and variable definitions (scala grammar not available)"
    pending "captures call expressions (scala grammar not available)"
    pending "captures import declarations (scala grammar not available)"
    pending "produces file nodes for Scala files (scala grammar not available)"
  end
end
