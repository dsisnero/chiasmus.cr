require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/walkers"
require "../../../src/chiasmus/graph/extractor"

include Chiasmus::Graph

describe "C# graph walker" do
  it "extracts class declarations from C# source" do
    cs = <<-CS
      namespace App {
        public class Service {
          public void Handle() {}
        }
      }
    CS
    sources = [SourceFile.new(path: "/tmp/test.cs", content: cs)]
    graph = Extractor.extract_graph(sources)
    graph.defines.size.should be >= 2
    names = graph.defines.map(&.name).to_set
    names.should contain("Service")
    names.should contain("Handle")
    kinds = graph.defines.map { |defn| {defn.name, defn.kind} }.to_h
    kinds["Service"].should eq(SymbolKind::Class)
    kinds["Handle"].should eq(SymbolKind::Method)
  end

  it "extracts interface declarations" do
    cs = <<-CS
      public interface IRepository<T> {
        T GetById(int id);
      }
    CS
    sources = [SourceFile.new(path: "/tmp/test2.cs", content: cs)]
    graph = Extractor.extract_graph(sources)
    names = graph.defines.map(&.name).to_set
    names.should contain("IRepository")
    kinds = graph.defines.map { |defn| {defn.name, defn.kind} }.to_h
    kinds["IRepository"].should eq(SymbolKind::Interface)
  end

  it "extracts struct and enum declarations" do
    cs = <<-CS
      public struct Point {
        public int X, Y;
      }
      public enum Color { Red, Green, Blue }
    CS
    sources = [SourceFile.new(path: "/tmp/test3.cs", content: cs)]
    graph = Extractor.extract_graph(sources)
    names = graph.defines.map(&.name).to_set
    names.should contain("Point")
    names.should contain("Color")
    kinds = graph.defines.map { |defn| {defn.name, defn.kind} }.to_h
    kinds["Point"].should eq(SymbolKind::Class)
    kinds["Color"].should eq(SymbolKind::Type)
  end

  it "extracts constructor declarations" do
    cs = <<-CS
      public class Widget {
        public Widget(string name) {}
      }
    CS
    sources = [SourceFile.new(path: "/tmp/test4.cs", content: cs)]
    graph = Extractor.extract_graph(sources)
    names = graph.defines.map(&.name).to_set
    names.should contain("Widget")
    names.should contain(".ctor")
    kinds = graph.defines.map { |defn| {defn.name, defn.kind} }.to_h
    kinds["Widget"].should eq(SymbolKind::Class)
    kinds[".ctor"].should eq(SymbolKind::Method)
  end

  it "captures method calls between classes" do
    cs = <<-CS
      public class Caller {
        public void Run() {
          var svc = new Service();
          svc.Handle();
        }
      }
      public class Service {
        public void Handle() {}
      }
    CS
    sources = [SourceFile.new(path: "/tmp/test5.cs", content: cs)]
    graph = Extractor.extract_graph(sources)
    callees = graph.calls.map(&.callee).to_set
    callees.should contain("Handle")
  end

  it "captures using directives as imports" do
    cs = <<-CS
      using System;
      using System.Collections.Generic;

      public class Foo {}
    CS
    sources = [SourceFile.new(path: "/tmp/test6.cs", content: cs)]
    graph = Extractor.extract_graph(sources)
    graph.imports.size.should be >= 1
    import_names = graph.imports.map(&.name).to_set
    import_names.should contain("System")
    import_names.should contain("System.Collections.Generic")
  end

  it "handles namespace scoping" do
    cs = <<-CS
      namespace MyApp.Core {
        public class Engine {
          public void Start() {}
        }
      }
    CS
    sources = [SourceFile.new(path: "/tmp/test7.cs", content: cs)]
    graph = Extractor.extract_graph(sources)
    graph.defines.size.should be >= 2
    graph.defines.map(&.name).should contain("Engine")
  end

  it "extracts summary from C# files" do
    cs = <<-CS
      public class Calculator {
        public int Add(int a, int b) => a + b;
        public int Subtract(int a, int b) => a - b;
      }
    CS
    sources = [SourceFile.new(path: "/tmp/test8.cs", content: cs)]
    graph = Extractor.extract_graph(sources)
    graph.files.should_not be_nil
    file_nodes = (graph.files || raise("nil files"))
    file_nodes.size.should eq(1)
    file_nodes[0].language.should eq("csharp")
  end
end
