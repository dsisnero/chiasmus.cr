require "../../spec_helper"
require "tree_sitter"

# Initialize grammar paths for tree-sitter tests
vendor_dir = File.expand_path("../../../vendor/grammars", __DIR__)
if Dir.exists?(vendor_dir)
  Chiasmus::Discovery.register_grammar_directory(vendor_dir)
end

# Helper to load TypeScript grammar for tests
private def typescript_language : TreeSitter::Language
  vendor_dir = File.expand_path("../../../vendor/grammars", __DIR__)
  ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
  lib_path = File.join(vendor_dir, "tree-sitter-typescript", "libtree-sitter-typescript.#{ext}")
  raise "TypeScript grammar not found at #{lib_path}" unless File.exists?(lib_path)

  handle = LibC.dlopen(lib_path.to_s, LibC::RTLD_LAZY | LibC::RTLD_LOCAL)
  ptr = LibC.dlsym(handle, "tree_sitter_typescript")
  lang_ptr = Proc(LibTreeSitter::TSLanguage*).new(ptr, Pointer(Void).null).call
  TreeSitter::Language.new("typescript", lang_ptr)
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
    parser = TreeSitter::Parser.new(language: lang)
    tree = parser.parse(nil, source)

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
    parser = TreeSitter::Parser.new(language: lang)
    tree = parser.parse(nil, source)

    extractor = Chiasmus::Discovery::TestExtractor.new
    items = extractor.extract(tree.root_node, source, "src/app.ts")

    func = items.find { |i| i.name == "hello" }
    func.should_not be_nil
    func.not_nil!.id.should eq("src/app.ts::function::hello")
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
