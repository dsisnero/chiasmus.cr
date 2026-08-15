require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/search/engine"
require "crig"

include Chiasmus::Search
include Chiasmus::Graph

# Mock Crig embedding model for tests
class MockEmbeddingModel
  include Crig::Embeddings::EmbeddingModel

  @dim : Int32

  def initialize(@dim : Int32)
  end

  def ndims : Int32
    @dim
  end

  def max_documents : Int32
    1000
  end

  def embed_text(text : String) : Crig::Embeddings::Embedding
    embed_texts([text]).first
  end

  def embed_texts(texts : Enumerable(String)) : Array(Crig::Embeddings::Embedding)
    texts.map do |text|
      v = Array(Float64).new(@dim, 0.0)
      text.each_char.with_index { |char, i| v[i % @dim] += char.ord.to_f / 1000.0 }
      Crig::Embeddings::Embedding.new(document: text, vec: v)
    end
  end

  def embed_images(images : Enumerable(Bytes)) : Array(Crig::Embeddings::Embedding)
    [] of Crig::Embeddings::Embedding
  end
end

class WrongDimensionEmbeddingModel
  include Crig::Embeddings::EmbeddingModel

  def ndims : Int32
    3
  end

  def max_documents : Int32
    1000
  end

  def embed_text(text : String) : Crig::Embeddings::Embedding
    Crig::Embeddings::Embedding.new(document: text, vec: [1.0, 0.0])
  end

  def embed_texts(texts : Enumerable(String)) : Array(Crig::Embeddings::Embedding)
    texts.map { |text| embed_text(text) }
  end

  def embed_images(images : Enumerable(Bytes)) : Array(Crig::Embeddings::Embedding)
    [] of Crig::Embeddings::Embedding
  end
end

describe SearchEngine do
  describe ".build_search_corpus" do
    it "preserves a callable signature in the embedding text and hit metadata" do
      signature = "def do_work(arg : Int32) : Bool"
      graph = CodeGraph.new(defines: [
        DefinesFact.new(file: "work.cr", name: "do_work", kind: SymbolKind::Method, span: Chiasmus::Graph::Span.line_range(1), signature: signature),
      ])
      corpus = SearchEngine.build_search_corpus(graph, {"work.cr" => "#{signature}\n  true\nend"})

      corpus.first.signature.should eq(signature)
      corpus.first.text.should contain(signature)
      SearchEngine.run_search("work", corpus, MockEmbeddingModel.new(3), 1).first.signature.should eq(signature)
    end

    it "creates entries for function defines" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "foo", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1)),
        ],
      )
      files = {"a.ts" => "function foo() {\n  return 42;\n}"}
      corpus = SearchEngine.build_search_corpus(graph, files)
      corpus.size.should eq 1
      corpus[0].name.should eq "foo"
    end

    it "skips non-callable defines" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "Foo", kind: SymbolKind::Class, span: Chiasmus::Graph::Span.line_range(1)),
          DefinesFact.new(file: "a.ts", name: "bar", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(3)),
        ],
      )
      files = {"a.ts" => "class Foo {}\nfunction bar() {}"}
      corpus = SearchEngine.build_search_corpus(graph, files)
      corpus.size.should eq 1
      corpus[0].name.should eq "bar"
    end

    it "skips defines with missing source files" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "missing.ts", name: "ghost", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1)),
        ],
      )
      files = {} of String => String
      corpus = SearchEngine.build_search_corpus(graph, files)
      corpus.should be_empty
    end

    it "uses syntax-aware chunks with leading comments for callable context" do
      source = <<-CR
        class Greeter
          # says hi
          def greet(name)
            puts name
          end

          def part(name)
            puts name
          end
        end
      CR

      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "greeter.cr", name: "greet", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(3, 5)),
          DefinesFact.new(file: "greeter.cr", name: "part", kind: SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(7, 9)),
        ],
      )
      files = {"greeter.cr" => source}

      corpus = SearchEngine.build_search_corpus(graph, files)
      greet = corpus.find(&.name.==("greet"))
      greet.should_not be_nil

      text = greet.not_nil!.text
      text.should contain("says hi")
      text.should contain("def greet")
      text.should_not contain("def part")
    end
  end

  describe ".run_search" do
    it "rejects embeddings whose dimension disagrees with the model" do
      corpus = [
        SearchCorpusEntry.new(id: "a", name: "a", file: "a.cr", line: 1, line_end: 1, signature: nil, leading_doc: nil, text: "a"),
      ]

      expect_raises(Chiasmus::Search::DimensionError, "VectorStore: expected dimension 3, got 2") do
        SearchEngine.run_search("query", corpus, WrongDimensionEmbeddingModel.new, 1)
      end
    end

    it "returns top-K hits using Crig EmbeddingModelDyn" do
      model = MockEmbeddingModel.new(3)
      corpus = [
        SearchCorpusEntry.new(
          id: "a.ts#foo#1", name: "foo", file: "a.ts", line: 1, line_end: 3,
          signature: nil, leading_doc: nil, text: "foo function",
        ),
        SearchCorpusEntry.new(
          id: "b.ts#bar#1", name: "bar", file: "b.ts", line: 1, line_end: 1,
          signature: nil, leading_doc: nil, text: "bar function",
        ),
      ]
      hits = SearchEngine.run_search("foo", corpus, model, 2)
      hits.should_not be_empty
      hits.first.name.should eq "foo"
      hits.first.line_end.should eq 3
    end

    it "returns empty for empty corpus" do
      model = MockEmbeddingModel.new(3)
      hits = SearchEngine.run_search("q", [] of SearchCorpusEntry, model, 5)
      hits.should be_empty
    end

    it "uses embedding cache when provided" do
      model = MockEmbeddingModel.new(3)
      corpus = [
        SearchCorpusEntry.new(
          id: "a.ts#f#1", name: "f", file: "a.ts", line: 1, line_end: 2,
          signature: nil, leading_doc: nil, text: "test text",
        ),
      ]

      dir = File.tempname("chiasmus-ecache-")
      Dir.mkdir(dir)
      begin
        path = File.join(dir, "cache.json")
        cache = EmbeddingCache.new(path, 3)
        SearchEngine.run_search("q", corpus, model, 1, cache)
        cache.save

        restored = EmbeddingCache.new(path, 3)
        restored.load
        restored.get("test text").should_not be_nil
      ensure
        Dir.children(dir).each { |child| File.delete(File.join(dir, child)) rescue nil }
        Dir.delete(dir) rescue nil
      end
    end
  end
end
