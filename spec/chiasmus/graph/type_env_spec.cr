require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/walkers"
require "../../../src/chiasmus/graph/extractor"
require "../../../src/chiasmus/graph/type_env"

include Chiasmus::Graph

describe TypeEnv do
  describe "process_method_definition" do
    it "does not crash on method with access modifier (child_count > named_child_count)" do
      ts = <<-TS
        class Foo {
          private x: number = 42;
          get y(): string { return "hello"; }
          bar(z: number): void {}
        }
      TS
      sources = [SourceFile.new(path: "/tmp/test.ts", content: ts)]
      graph = Extractor.extract_graph(sources)
      graph.defines.size.should be >= 1
    end
  end

  describe "process_field_definition" do
    it "does not crash when scanning field children for type_annotation" do
      ts = <<-TS
        class Bar {
          public count: number = 0;
          protected name: string = "test";
        }
      TS
      sources = [SourceFile.new(path: "/tmp/test2.ts", content: ts)]
      graph = Extractor.extract_graph(sources)
      graph.defines.size.should be >= 1
    end
  end

  describe "process_property_signature" do
    it "produces DefinesFact for interfaces (upstream parity)" do
      ts = <<-TS
        interface Foo {
          bar(): string;
        }
        class Baz implements Foo {
          bar(): string { return "hi"; }
        }
      TS
      sources = [SourceFile.new(path: "/tmp/iface.ts", content: ts)]
      graph = Extractor.extract_graph(sources)
      graph.defines.size.should be >= 3
      kinds = graph.defines.map(&.kind)
      kinds.should contain(SymbolKind::Interface)
      names = graph.defines.map(&.name)
      names.should contain("Foo")
    end
  end

  describe "vendor failing files" do
    it "parses formalize/engine.ts without Index out of bounds" do
      f = File.expand_path("vendor/chiasmus/src/formalize/engine.ts")
      sources = [SourceFile.new(path: f, content: File.read(f))]
      graph = Extractor.extract_graph(sources)
      graph.defines.size.should be >= 1
    end

    it "parses llm/anthropic.ts without Index out of bounds" do
      f = File.expand_path("vendor/chiasmus/src/llm/anthropic.ts")
      sources = [SourceFile.new(path: f, content: File.read(f))]
      graph = Extractor.extract_graph(sources)
      graph.defines.size.should be >= 1
    end

    it "parses skills/learner.ts without Index out of bounds" do
      f = File.expand_path("vendor/chiasmus/src/skills/learner.ts")
      sources = [SourceFile.new(path: f, content: File.read(f))]
      graph = Extractor.extract_graph(sources)
      graph.defines.size.should be >= 1
    end

    it "parses search/embedding-cache.ts without Index out of bounds" do
      f = File.expand_path("vendor/chiasmus/src/search/embedding-cache.ts")
      sources = [SourceFile.new(path: f, content: File.read(f))]
      graph = Extractor.extract_graph(sources)
      graph.defines.size.should be >= 1
    end

    it "parses solvers/session.ts without Index out of bounds" do
      f = File.expand_path("vendor/chiasmus/src/solvers/session.ts")
      sources = [SourceFile.new(path: f, content: File.read(f))]
      graph = Extractor.extract_graph(sources)
      graph.defines.size.should be >= 1
    end
  end
end
