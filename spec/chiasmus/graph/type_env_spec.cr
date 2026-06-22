require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/walkers"
require "../../../src/chiasmus/graph/extractor"
require "../../../src/chiasmus/graph/type_env"

include Chiasmus::Graph

private def upstream_fixture(relative_path : String) : String
  File.expand_path(File.join("../../testdata/upstream/chiasmus", relative_path), __DIR__)
end

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

  describe "upstream fixture files" do
    it "parses formalize/engine.ts without Index out of bounds" do
      fixture = upstream_fixture("src/formalize/engine.ts")
      sources = [SourceFile.new(path: fixture, content: File.read(fixture))]
      graph = Extractor.extract_graph(sources)
      graph.defines.size.should be >= 1
    end

    it "parses llm/anthropic.ts without Index out of bounds" do
      fixture = upstream_fixture("src/llm/anthropic.ts")
      sources = [SourceFile.new(path: fixture, content: File.read(fixture))]
      graph = Extractor.extract_graph(sources)
      graph.defines.size.should be >= 1
    end

    it "parses skills/learner.ts without Index out of bounds" do
      fixture = upstream_fixture("src/skills/learner.ts")
      sources = [SourceFile.new(path: fixture, content: File.read(fixture))]
      graph = Extractor.extract_graph(sources)
      graph.defines.size.should be >= 1
    end

    it "parses search/embedding-cache.ts without Index out of bounds" do
      fixture = upstream_fixture("src/search/embedding-cache.ts")
      sources = [SourceFile.new(path: fixture, content: File.read(fixture))]
      graph = Extractor.extract_graph(sources)
      graph.defines.size.should be >= 1
    end

    it "parses solvers/session.ts without Index out of bounds" do
      fixture = upstream_fixture("src/solvers/session.ts")
      sources = [SourceFile.new(path: fixture, content: File.read(fixture))]
      graph = Extractor.extract_graph(sources)
      graph.defines.size.should be >= 1
    end
  end
end
