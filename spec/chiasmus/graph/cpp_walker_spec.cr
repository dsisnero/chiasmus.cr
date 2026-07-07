require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/walkers"
require "../../../src/chiasmus/graph/extractor"
require "tree-sitter-manager"

include Chiasmus::Graph

describe "C++ graph walker" do
  if TreeSitterManager::GrammarLoader.tree_sitter_available?("cpp")
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

    it "tracks namespace names in defines" do
      code = <<-CPP
        namespace app {
          class Parser {
            void parse();
          };
        }
      CPP
      sources = [SourceFile.new(path: "/tmp/t.cpp", content: code)]
      graph = Extractor.extract_graph(sources)
      names = graph.defines.map(&.name).to_set
      names.should contain("app")
      names.should contain("Parser")
      names.should contain("parse")
    end

    it "extracts enum declarations and members" do
      code = <<-CPP
        enum Color { RED, GREEN, BLUE };
      CPP
      sources = [SourceFile.new(path: "/tmp/t.cpp", content: code)]
      graph = Extractor.extract_graph(sources)
      names = graph.defines.map(&.name).to_set
      names.should contain("Color")
      names.should contain("RED")
      names.should contain("GREEN")
      names.should contain("BLUE")
    end

    it "extracts class enum declarations and members" do
      code = <<-CPP
        enum class Status { OK, ERROR };
      CPP
      sources = [SourceFile.new(path: "/tmp/t.cpp", content: code)]
      graph = Extractor.extract_graph(sources)
      names = graph.defines.map(&.name).to_set
      names.should contain("Status")
      names.should contain("OK")
      names.should contain("ERROR")
    end

    it "extracts constructor definitions" do
      code = <<-CPP
        class Widget {
          Widget(int x) {}
        };
      CPP
      sources = [SourceFile.new(path: "/tmp/t.cpp", content: code)]
      graph = Extractor.extract_graph(sources)
      names = graph.defines.map(&.name).to_set
      names.should contain("Widget")
      names.should contain(".ctor")
    end

    it "extracts destructor definitions" do
      code = <<-CPP
        class Resource {
          ~Resource() {}
        };
      CPP
      sources = [SourceFile.new(path: "/tmp/t.cpp", content: code)]
      graph = Extractor.extract_graph(sources)
      names = graph.defines.map(&.name).to_set
      names.should contain("Resource")
      names.should contain(".dtor")
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
  else
    pending "extracts class declarations (cpp grammar not available)"
    pending "extracts struct declarations (cpp grammar not available)"
    pending "extracts free functions (cpp grammar not available)"
    pending "captures function calls (cpp grammar not available)"
    pending "captures #include directives as imports (cpp grammar not available)"
    pending "handles namespace declarations (cpp grammar not available)"
    pending "tracks namespace names in defines (cpp grammar not available)"
    pending "extracts enum declarations and members (cpp grammar not available)"
    pending "extracts class enum declarations and members (cpp grammar not available)"
    pending "extracts constructor definitions (cpp grammar not available)"
    pending "extracts destructor definitions (cpp grammar not available)"
    pending "produces file nodes for C++ files (cpp grammar not available)"
  end
end
