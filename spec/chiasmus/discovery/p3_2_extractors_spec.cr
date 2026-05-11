require "../../spec_helper"
require "tree_sitter"

vendor_dir = File.expand_path("../../../vendor/grammars", __DIR__)
if Dir.exists?(vendor_dir)
  Chiasmus::Discovery.register_grammar_directory(vendor_dir)
end

describe Chiasmus::Discovery::JavaScriptExtractor do
  it "extracts class declarations" do
    extractor = Chiasmus::Discovery::JavaScriptExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("javascript").not_nil!
    parser = TreeSitter::Parser.new(language: lang)
    source = "class Counter {}\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.js")
    classes = items.select { |i| i.kind == "class" }
    classes.map(&.name).should contain("Counter")
  end

  it "extracts function declarations" do
    extractor = Chiasmus::Discovery::JavaScriptExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("javascript").not_nil!
    parser = TreeSitter::Parser.new(language: lang)
    source = "function hello() {}\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.js")
    functions = items.select { |i| i.kind == "function" }
    functions.map(&.name).should contain("hello")
  end

  it "extracts arrow functions" do
    extractor = Chiasmus::Discovery::JavaScriptExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("javascript").not_nil!
    parser = TreeSitter::Parser.new(language: lang)
    source = "const fn = () => {}\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.js")
    functions = items.select { |i| i.kind == "function" }
    functions.map(&.name).should contain("fn")
  end

  it "extracts UPPERCASE constants" do
    extractor = Chiasmus::Discovery::JavaScriptExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("javascript").not_nil!
    parser = TreeSitter::Parser.new(language: lang)
    source = "const API_URL = 'http://localhost'\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.js")
    consts = items.select { |i| i.kind == "const" }
    consts.map(&.name).should contain("API_URL")
  end
end

describe Chiasmus::Discovery::RubyExtractor do
  it "extracts class definitions" do
    extractor = Chiasmus::Discovery::RubyExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("ruby").not_nil!
    parser = TreeSitter::Parser.new(language: lang)
    source = "class MyClass\nend\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.rb")
    classes = items.select { |i| i.kind == "class" }
    classes.map(&.name).should contain("MyClass")
  end

  it "extracts module as interface" do
    extractor = Chiasmus::Discovery::RubyExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("ruby").not_nil!
    parser = TreeSitter::Parser.new(language: lang)
    source = "module Namespace\nend\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.rb")
    interfaces = items.select { |i| i.kind == "interface" }
    interfaces.map(&.name).should contain("Namespace")
  end

  it "extracts methods with class-qualified names" do
    extractor = Chiasmus::Discovery::RubyExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("ruby").not_nil!
    parser = TreeSitter::Parser.new(language: lang)
    source = "class Foo\n  def bar\n  end\nend\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.rb")
    methods = items.select { |i| i.kind == "method" }
    methods.map(&.name).should contain("Foo.bar")
  end
end

describe Chiasmus::Discovery::CrystalExtractor do
  it "extracts class_def" do
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("crystal").not_nil!
    parser = TreeSitter::Parser.new(language: lang)
    source = "class Foo\nend\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.cr")
    classes = items.select { |i| i.kind == "class" }
    classes.map(&.name).should contain("Foo")
  end

  it "extracts struct_def" do
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("crystal").not_nil!
    parser = TreeSitter::Parser.new(language: lang)
    source = "struct Point\nend\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.cr")
    classes = items.select { |i| i.kind == "class" }
    classes.map(&.name).should contain("Point")
  end

  it "extracts module_def as interface" do
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("crystal").not_nil!
    parser = TreeSitter::Parser.new(language: lang)
    source = "module Chiasmus\nend\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.cr")
    interfaces = items.select { |i| i.kind == "interface" }
    interfaces.map(&.name).should contain("Chiasmus")
  end

  it "extracts method_def" do
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("crystal").not_nil!
    parser = TreeSitter::Parser.new(language: lang)
    source = "class Foo\n  def bar\n  end\nend\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.cr")
    methods = items.select { |i| i.kind == "method" }
    methods.map(&.name).should contain("Foo.bar")
  end
end

describe Chiasmus::Discovery::ScalaExtractor do
  it "extracts class_definition" do
    extractor = Chiasmus::Discovery::ScalaExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("scala").not_nil!
    parser = TreeSitter::Parser.new(language: lang)
    source = "class Foo {}\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.scala")
    classes = items.select { |i| i.kind == "class" }
    classes.map(&.name).should contain("Foo")
  end

  it "extracts object_definition as class" do
    extractor = Chiasmus::Discovery::ScalaExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("scala").not_nil!
    parser = TreeSitter::Parser.new(language: lang)
    source = "object Bar {}\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.scala")
    classes = items.select { |i| i.kind == "class" }
    classes.map(&.name).should contain("Bar")
  end

  it "extracts trait_definition as interface" do
    extractor = Chiasmus::Discovery::ScalaExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("scala").not_nil!
    parser = TreeSitter::Parser.new(language: lang)
    source = "trait Runnable {}\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.scala")
    interfaces = items.select { |i| i.kind == "interface" }
    interfaces.map(&.name).should contain("Runnable")
  end

  it "extracts function_definition" do
    extractor = Chiasmus::Discovery::ScalaExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("scala").not_nil!
    parser = TreeSitter::Parser.new(language: lang)
    source = "def greet(): Unit = {}\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.scala")
    functions = items.select { |i| i.kind == "function" }
    functions.map(&.name).should contain("greet")
  end
end
