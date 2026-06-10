require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/walkers"
require "../../../src/chiasmus/graph/extractor"

include Chiasmus::Graph

describe "PHP graph walker" do
  it "extracts class declarations and methods" do
    code = <<-PHP
      <?php
      class Calculator {
        public function add($a, $b) {
          return $a + $b;
        }
      }
    PHP
    sources = [SourceFile.new(path: "/tmp/t.php", content: code)]
    graph = Extractor.extract_graph(sources)
    names = graph.defines.map(&.name).to_set
    names.should contain("Calculator")
    names.should contain("add")
  end

  it "extracts function definitions" do
    code = <<-PHP
      <?php
      function greet($name) {
        return "Hello, $name";
      }
    PHP
    sources = [SourceFile.new(path: "/tmp/t.php", content: code)]
    graph = Extractor.extract_graph(sources)
    graph.defines.map(&.name).should contain("greet")
  end

  it "captures function calls" do
    code = <<-PHP
      <?php
      function helper() {}
      function caller() {
        helper();
      }
    PHP
    sources = [SourceFile.new(path: "/tmp/t.php", content: code)]
    graph = Extractor.extract_graph(sources)
    callees = graph.calls.map(&.callee).to_set
    callees.should contain("helper")
  end

  it "captures namespace use clauses" do
    code = <<-PHP
      <?php
      use App\\Services\\Logger;
      use App\\Models\\User;
      class App {}
    PHP
    sources = [SourceFile.new(path: "/tmp/t.php", content: code)]
    graph = Extractor.extract_graph(sources)
    graph.imports.size.should be >= 2
  end

  it "produces file nodes for PHP files" do
    code = "<?php echo 'hello';"
    sources = [SourceFile.new(path: "/tmp/t.php", content: code)]
    graph = Extractor.extract_graph(sources)
    graph.files.should_not be_nil
    (graph.files || raise("nil")).first.language.should eq("php")
  end
end
