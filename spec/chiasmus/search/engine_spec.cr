require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/search/engine"

include Chiasmus::Search
include Chiasmus::Graph

# Mock embedding adapter for tests
class MockEmbeddingAdapter
  include EmbeddingAdapter
  @dim : Int32

  def initialize(@dim : Int32)
  end

  def dimension : Int32
    @dim
  end

  def embed(texts : Array(String)) : Array(Array(Float64))
    # Deterministic: hash each text into a fixed-dim vector
    texts.map do |t|
      v = Array(Float64).new(@dim, 0.0)
      t.each_char.with_index { |c, i| v[i % @dim] += c.ord.to_f / 1000.0 }
      v
    end
  end
end

describe SearchEngine do
  describe ".build_search_corpus" do
    it "creates entries for function defines" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "foo", kind: SymbolKind::Function, line: 1),
        ],
      )
      files = {"a.ts" => "function foo() {\n  return 42;\n}"}
      corpus = SearchEngine.build_search_corpus(graph, files)
      corpus.size.should eq 1
      corpus[0].name.should eq "foo"
      corpus[0].file.should eq "a.ts"
    end

    it "skips non-callable defines" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "a.ts", name: "Foo", kind: SymbolKind::Class, line: 1),
          DefinesFact.new(file: "a.ts", name: "bar", kind: SymbolKind::Function, line: 3),
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
          DefinesFact.new(file: "missing.ts", name: "ghost", kind: SymbolKind::Function, line: 1),
        ],
      )
      files = {} of String => String
      corpus = SearchEngine.build_search_corpus(graph, files)
      corpus.should be_empty
    end
  end

  describe ".run_search" do
    it "returns top-K hits" do
      adapter = MockEmbeddingAdapter.new(3)
      corpus = [
        SearchCorpusEntry.new(
          id: "a.ts#foo#1", name: "foo", file: "a.ts", line: 1,
          signature: nil, leading_doc: nil, text: "foo function",
        ),
        SearchCorpusEntry.new(
          id: "b.ts#bar#1", name: "bar", file: "b.ts", line: 1,
          signature: nil, leading_doc: nil, text: "bar function",
        ),
      ]
      hits = SearchEngine.run_search("foo", corpus, adapter, 2)
      hits.should_not be_empty
      hits.first.name.should eq "foo"
    end

    it "returns empty for empty corpus" do
      adapter = MockEmbeddingAdapter.new(3)
      hits = SearchEngine.run_search("q", [] of SearchCorpusEntry, adapter, 5)
      hits.should be_empty
    end

    it "uses cache when provided" do
      adapter = MockEmbeddingAdapter.new(3)
      corpus = [
        SearchCorpusEntry.new(
          id: "a.ts#f#1", name: "f", file: "a.ts", line: 1,
          signature: nil, leading_doc: nil, text: "test text",
        ),
      ]

      with_temp_cache do |cache, dir|
        # First run embeds and caches
        SearchEngine.run_search("q", corpus, adapter, 1, cache)
        cache.save

        # Restore cache, verify hit
        restored = EmbeddingCache.new(File.join(dir, "cache.json"), 3)
        restored.load
        restored.get("test text").should_not be_nil
      end
    end
  end
end

private def with_temp_cache(& : EmbeddingCache, String ->)
  dir = File.tempname("chiasmus-ecache-")
  Dir.mkdir(dir)
  begin
    path = File.join(dir, "cache.json")
    cache = EmbeddingCache.new(path, 3)
    yield cache, dir
  ensure
    Dir.children(dir).each { |c| File.delete(File.join(dir, c)) rescue nil }
    Dir.delete(dir) rescue nil
  end
end
