require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/walkers"
require "../../../src/chiasmus/graph/extractor"

include Chiasmus::Graph

describe "C graph walker" do
  it "extracts function definitions" do
    code = <<-C
      int add(int a, int b) {
        return a + b;
      }
    C
    sources = [SourceFile.new(path: "/tmp/t.c", content: code)]
    graph = Extractor.extract_graph(sources)
    graph.defines.map(&.name).should contain("add")
  end

  it "extracts struct declarations" do
    code = <<-C
      struct Point {
        int x;
        int y;
      };
    C
    sources = [SourceFile.new(path: "/tmp/t.c", content: code)]
    graph = Extractor.extract_graph(sources)
    names = graph.defines.map(&.name).to_set
    names.should contain("Point")
  end

  it "extracts enum declarations as types" do
    code = <<-C
      enum Color { RED, GREEN, BLUE };
    C
    sources = [SourceFile.new(path: "/tmp/t.c", content: code)]
    graph = Extractor.extract_graph(sources)
    type_defs = graph.defines.select { |defn| defn.kind == SymbolKind::Type }
    type_defs.map(&.name).should contain("Color")
  end

  it "captures function calls" do
    code = <<-C
      void helper() {}
      void caller() {
        helper();
      }
    C
    sources = [SourceFile.new(path: "/tmp/t.c", content: code)]
    graph = Extractor.extract_graph(sources)
    callees = graph.calls.map(&.callee).to_set
    callees.should contain("helper")
  end

  it "captures #include directives as imports" do
    code = <<-C
      #include <stdio.h>
      #include "mylib.h"
      int main() {}
    C
    sources = [SourceFile.new(path: "/tmp/t.c", content: code)]
    graph = Extractor.extract_graph(sources)
    graph.imports.size.should be >= 2
    import_names = graph.imports.map(&.name).to_set
    import_names.should contain("stdio.h")
    import_names.should contain("mylib.h")
  end

  it "produces file nodes for C files" do
    code = "int main() { return 0; }"
    sources = [SourceFile.new(path: "/tmp/t.c", content: code)]
    graph = Extractor.extract_graph(sources)
    graph.files.should_not be_nil
    (graph.files || raise("nil")).first.language.should eq("c")
  end
end
