require "../../spec_helper"
require "tree_sitter"

# Initialize grammar paths for tree-sitter tests
vendor_dir = File.expand_path("../../../grammars", __DIR__)
if Dir.exists?(vendor_dir)
  Chiasmus::Discovery.register_grammar_directory(vendor_dir)
end

# Helper to load TypeScript grammar for tests
private def typescript_language : TreeSitter::Language?
  TreeSitterManager::GrammarLoader.load_language("typescript")
end

private struct CacheKeyExtractor < Chiasmus::Discovery::QueryExtractor
  def initialize(@query_src : String)
  end

  def language : String
    "cache-key"
  end

  def extensions : Array(String)
    [".cache-key"]
  end

  def grammar_language : String
    "typescript"
  end

  def queries : Hash(String, String)
    {"symbol" => @query_src}
  end
end

describe Chiasmus::Discovery::LanguageExtractor do
  it "concrete extractor implements required interface" do
    extractor = Chiasmus::Discovery::TestExtractor.new
    extractor.language.should be_a(String)
    extractor.language.should eq("typescript")
    extractor.extensions.should be_a(Array(String))
    extractor.extensions.should contain(".ts")
    extractor.grammar_language.should be_a(String)
  end
end

describe Chiasmus::Discovery::QueryExtractor do
  it "provides queries hash for tree-sitter patterns" do
    extractor = Chiasmus::Discovery::TestExtractor.new
    extractor.queries.should be_a(Hash(String, String))
    extractor.queries.has_key?("class").should be_true
  end

  it "provides post_filter for kind-specific filtering" do
    extractor = Chiasmus::Discovery::TestExtractor.new
    result = extractor.post_filter("class", "Foo", nil, "")
    result.should eq("Foo")
  end

  it "extracts classes from AST using queries" do
    source = <<-TS
      class MyService {}
    TS

    lang = typescript_language
    next pending "typescript grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    tree = parser.parse(source)

    extractor = Chiasmus::Discovery::TestExtractor.new
    items = extractor.extract(tree.root_node, source, "test.ts")

    classes = items.select { |i| i.kind == "class" }
    classes.map(&.name).should contain("MyService")
  end

  it "produces items with correct ID format" do
    source = <<-TS
      function hello() {}
    TS

    lang = typescript_language
    next pending "typescript grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    tree = parser.parse(source)

    extractor = Chiasmus::Discovery::TestExtractor.new
    items = extractor.extract(tree.root_node, source, "src/app.ts")

    func = items.find { |i| i.name == "hello" }
    func.should_not be_nil
    raise "expected non-nil func" if func.nil?
    func.id.should eq("src/app.ts::function::hello")
  end

  it "reuses compiled queries and loaded language across extractions" do
    source = <<-TS
      class MyService {}
      function hello() {}
    TS

    lang = typescript_language
    next pending "typescript grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    tree = parser.parse(source)

    extractor = Chiasmus::Discovery::TestExtractor.new
    extractor.clear_caches_for_test

    extractor.extract(tree.root_node, source, "a.ts")
    first_counts = extractor.cache_counts_for_test

    extractor.extract(tree.root_node, source, "b.ts")
    second_counts = extractor.cache_counts_for_test

    first_counts[:languages].should be > 0
    first_counts[:queries].should be > 0
    second_counts.should eq(first_counts)
  end

  it "caches distinct query sources independently for the same grammar and kind" do
    source = <<-TS
      class MyService {}
      function hello() {}
    TS

    lang = typescript_language
    next pending "typescript grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    tree = parser.parse(source)

    class_extractor = CacheKeyExtractor.new("(class_declaration name: (type_identifier) @name) @def")
    function_extractor = CacheKeyExtractor.new("(function_declaration name: (identifier) @name) @def")
    class_extractor.clear_caches_for_test

    class_extractor.extract(tree.root_node, source, "cache.ts").map(&.name).should eq(["MyService"])
    function_extractor.extract(tree.root_node, source, "cache.ts").map(&.name).should eq(["hello"])
    function_extractor.cache_counts_for_test[:queries].should eq(2)
  end
end

describe Chiasmus::Discovery::ExtractorRegistry do
  it "maps file extensions to extractors" do
    registry = Chiasmus::Discovery::ExtractorRegistry.new([
      Chiasmus::Discovery::TestExtractor.new,
    ])

    extractor = registry.for_file("test.ts")
    extractor.should_not be_nil
  end

  it "returns nil for unknown extensions" do
    registry = Chiasmus::Discovery::ExtractorRegistry.new([
      Chiasmus::Discovery::TestExtractor.new,
    ])

    extractor = registry.for_file("test.unknown")
    extractor.should be_nil
  end

  it "returns all supported extensions" do
    registry = Chiasmus::Discovery::ExtractorRegistry.new([
      Chiasmus::Discovery::TestExtractor.new,
    ])

    registry.supported_extensions.should contain(".ts")
  end

  it "deduplicates extractors by language" do
    registry = Chiasmus::Discovery::ExtractorRegistry.new([
      Chiasmus::Discovery::TestExtractor.new,
      Chiasmus::Discovery::TestExtractor.new,
    ])

    registry.size.should eq(1)
  end
end
