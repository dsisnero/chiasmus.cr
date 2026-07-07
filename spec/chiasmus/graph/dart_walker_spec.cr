require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/walkers"
require "../../../src/chiasmus/graph/extractor"
require "tree-sitter-manager"

include Chiasmus::Graph

describe "Dart graph walker" do
  if TreeSitterManager::GrammarLoader.tree_sitter_available?("dart")
    it "extracts class definitions" do
      code = <<-DART
        class Calculator {
          int add(int a, int b) {
            return a + b;
          }
        }
      DART
      sources = [SourceFile.new(path: "/tmp/t.dart", content: code)]
      graph = Extractor.extract_graph(sources)
      names = graph.defines.map(&.name).to_set
      names.should contain("Calculator")
      names.should contain("add")
    end

    it "extracts top-level function signatures" do
      code = <<-DART
        int max(int a, int b) {
          return a > b ? a : b;
        }
      DART
      sources = [SourceFile.new(path: "/tmp/t.dart", content: code)]
      graph = Extractor.extract_graph(sources)
      graph.defines.map(&.name).should contain("max")
    end

    it "captures function invocations" do
      code = <<-DART
        void helper() {}
        void caller() {
          helper();
        }
      DART
      sources = [SourceFile.new(path: "/tmp/t.dart", content: code)]
      graph = Extractor.extract_graph(sources)
      callees = graph.calls.map(&.callee).to_set
      callees.should contain("helper")
    end

    it "captures import directives" do
      code = <<-DART
        import 'dart:math';
        import 'package:test/test.dart';
        void main() {}
      DART
      sources = [SourceFile.new(path: "/tmp/t.dart", content: code)]
      graph = Extractor.extract_graph(sources)
      graph.imports.size.should be >= 2
    end

    it "extracts enum declarations" do
      code = <<-DART
        enum Color { red, green, blue }
      DART
      sources = [SourceFile.new(path: "/tmp/t.dart", content: code)]
      graph = Extractor.extract_graph(sources)
      names = graph.defines.map(&.name).to_set
      names.should contain("Color")
    end

    it "captures constructor declarations" do
      code = <<-DART
        class Point {
          int x, y;
          Point(this.x, this.y);
        }
      DART
      sources = [SourceFile.new(path: "/tmp/t.dart", content: code)]
      graph = Extractor.extract_graph(sources)
      names = graph.defines.map(&.name).to_set
      names.should contain("Point")
      names.should contain(".ctor")
    end

    it "produces file nodes for Dart files" do
      code = "void main() {}"
      sources = [SourceFile.new(path: "/tmp/t.dart", content: code)]
      graph = Extractor.extract_graph(sources)
      graph.files.should_not be_nil
      (graph.files || raise("nil")).first.language.should eq("dart")
    end
  else
    pending "extracts class definitions (dart grammar not available)"
    pending "extracts top-level function signatures (dart grammar not available)"
    pending "captures function invocations (dart grammar not available)"
    pending "captures import directives (dart grammar not available)"
    pending "extracts enum declarations (dart grammar not available)"
    pending "captures constructor declarations (dart grammar not available)"
    pending "produces file nodes for Dart files (dart grammar not available)"
  end
end
