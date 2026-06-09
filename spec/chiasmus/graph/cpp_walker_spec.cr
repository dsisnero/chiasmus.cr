require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/walkers"
require "../../../src/chiasmus/graph/extractor"

include Chiasmus::Graph

describe "C++ graph walker" do
  it "extracts class declarations" do
    code = <<-CPP
      class Calculator {
      public:
        int add(int a, int b);
        int subtract(int a, int b);
      };
    CPP
    sources = [SourceFile.new(path: "/tmp/t.cpp", content: code)]
    graph = Extractor.extract_graph(sources)
    names = graph.defines.map(&.name).to_set
    names.should contain("Calculator")
    names.should contain("add")
    names.should contain("subtract")
  end

  it "extracts struct declarations" do
    code = <<-CPP
      struct Point {
        int x;
        int y;
      };
    CPP
    sources = [SourceFile.new(path: "/tmp/t.cpp", content: code)]
    graph = Extractor.extract_graph(sources)
    graph.defines.map(&.name).should contain("Point")
  end

  it "extracts free functions" do
    code = <<-CPP
      int max(int a, int b) {
        return a > b ? a : b;
      }
    CPP
    sources = [SourceFile.new(path: "/tmp/t.cpp", content: code)]
    graph = Extractor.extract_graph(sources)
    graph.defines.map(&.name).should contain("max")
  end

  it "captures function calls" do
    code = <<-CPP
      void helper() {}
      void caller() {
        helper();
      }
    CPP
    sources = [SourceFile.new(path: "/tmp/t.cpp", content: code)]
    graph = Extractor.extract_graph(sources)
    callees = graph.calls.map(&.callee).to_set
    callees.should contain("helper")
  end

  it "captures #include directives as imports" do
    code = <<-CPP
      #include <iostream>
      #include "mylib.h"
      int main() {}
    CPP
    sources = [SourceFile.new(path: "/tmp/t.cpp", content: code)]
    graph = Extractor.extract_graph(sources)
    graph.imports.size.should be >= 2
    import_names = graph.imports.map(&.name).to_set
    import_names.should contain("iostream")
    import_names.should contain("mylib.h")
  end

  it "handles namespace declarations" do
    code = <<-CPP
      namespace app {
        class Service {
          void handle();
        };
      }
    CPP
    sources = [SourceFile.new(path: "/tmp/t.cpp", content: code)]
    graph = Extractor.extract_graph(sources)
    graph.defines.size.should be >= 2
  end

  it "produces file nodes for C++ files" do
    code = <<-CPP
      int main() { return 0; }
    CPP
    sources = [SourceFile.new(path: "/tmp/t.cpp", content: code)]
    graph = Extractor.extract_graph(sources)
    graph.files.should_not be_nil
    (graph.files || raise("nil")).first.language.should eq("cpp")
  end
end
