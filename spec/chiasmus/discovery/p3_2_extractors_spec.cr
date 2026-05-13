require "../../spec_helper"
require "tree_sitter"

vendor_dir = File.expand_path("../../../vendor/grammars", __DIR__)
if Dir.exists?(vendor_dir)
  Chiasmus::Discovery.register_grammar_directory(vendor_dir)
end

# Helper: load language or skip test (grammar may not be compiled in CI)
private def load_lang(name)
  Chiasmus::Discovery::GrammarLoader.load_language(name)
end

describe Chiasmus::Discovery::JavaScriptExtractor do
  it "extracts class declarations" do
    extractor = Chiasmus::Discovery::JavaScriptExtractor.new
    lang = load_lang("javascript")
    pending "javascript grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "class Counter {}\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.js")
    classes = items.select { |i| i.kind == "class" }
    classes.map(&.name).should contain("Counter")
  end

  it "extracts function declarations" do
    extractor = Chiasmus::Discovery::JavaScriptExtractor.new
    lang = load_lang("javascript")
    pending "javascript grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "function hello() {}\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.js")
    functions = items.select { |i| i.kind == "function" }
    functions.map(&.name).should contain("hello")
  end

  it "extracts arrow functions" do
    extractor = Chiasmus::Discovery::JavaScriptExtractor.new
    lang = load_lang("javascript")
    pending "javascript grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "const fn = () => {}\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.js")
    functions = items.select { |i| i.kind == "function" }
    functions.map(&.name).should contain("fn")
  end

  it "extracts UPPERCASE constants" do
    extractor = Chiasmus::Discovery::JavaScriptExtractor.new
    lang = load_lang("javascript")
    pending "javascript grammar not available" unless lang
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
    lang = load_lang("ruby")
    pending "ruby grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "class MyClass\nend\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.rb")
    classes = items.select { |i| i.kind == "class" }
    classes.map(&.name).should contain("MyClass")
  end

  it "extracts module as interface" do
    extractor = Chiasmus::Discovery::RubyExtractor.new
    lang = load_lang("ruby")
    pending "ruby grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "module Namespace\nend\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.rb")
    interfaces = items.select { |i| i.kind == "interface" }
    interfaces.map(&.name).should contain("Namespace")
  end

  it "extracts methods with class-qualified names" do
    extractor = Chiasmus::Discovery::RubyExtractor.new
    lang = load_lang("ruby")
    pending "ruby grammar not available" unless lang
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
    lang = load_lang("crystal")
    pending "crystal grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "class Foo\nend\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.cr")
    classes = items.select { |i| i.kind == "class" }
    classes.map(&.name).should contain("Foo")
  end

  it "extracts struct_def" do
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    lang = load_lang("crystal")
    pending "crystal grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "struct Point\nend\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.cr")
    classes = items.select { |i| i.kind == "class" }
    classes.map(&.name).should contain("Point")
  end

  it "extracts module_def as interface" do
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    lang = load_lang("crystal")
    pending "crystal grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "module Chiasmus\nend\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.cr")
    interfaces = items.select { |i| i.kind == "interface" }
    interfaces.map(&.name).should contain("Chiasmus")
  end

  it "extracts method_def" do
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    lang = load_lang("crystal")
    pending "crystal grammar not available" unless lang
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
    lang = load_lang("scala")
    pending "scala grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "class Foo {}\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.scala")
    classes = items.select { |i| i.kind == "class" }
    classes.map(&.name).should contain("Foo")
  end

  it "extracts object_definition as class" do
    extractor = Chiasmus::Discovery::ScalaExtractor.new
    lang = load_lang("scala")
    pending "scala grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "object Bar {}\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.scala")
    classes = items.select { |i| i.kind == "class" }
    classes.map(&.name).should contain("Bar")
  end

  it "extracts trait_definition as interface" do
    extractor = Chiasmus::Discovery::ScalaExtractor.new
    lang = load_lang("scala")
    pending "scala grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "trait Runnable {}\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.scala")
    interfaces = items.select { |i| i.kind == "interface" }
    interfaces.map(&.name).should contain("Runnable")
  end

  it "extracts function_definition" do
    extractor = Chiasmus::Discovery::ScalaExtractor.new
    lang = load_lang("scala")
    pending "scala grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "def greet(): Unit = {}\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.scala")
    functions = items.select { |i| i.kind == "function" }
    functions.map(&.name).should contain("greet")
  end
end

# P7.6 Class fields extraction specs
describe Chiasmus::Discovery::GoExtractor do
  it "extracts struct fields" do
    extractor = Chiasmus::Discovery::GoExtractor.new
    lang = load_lang("go")
    pending "go grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "package main\ntype Server struct {\n  Name string\n  Port int\n}\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.go")
    fields = items.select { |i| i.kind == "field" }
    fields.map(&.name).should contain("Name")
    fields.map(&.name).should contain("Port")
  end
end

describe Chiasmus::Discovery::JavaExtractor do
  it "extracts class fields" do
    extractor = Chiasmus::Discovery::JavaExtractor.new
    lang = load_lang("java")
    pending "java grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "class X { private String name; int count; }\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.java")
    fields = items.select { |i| i.kind == "field" }
    fields.map(&.name).should contain("name")
    fields.map(&.name).should contain("count")
  end
end

describe Chiasmus::Discovery::JavaScriptExtractor do
  it "extracts class field_definition" do
    extractor = Chiasmus::Discovery::JavaScriptExtractor.new
    lang = load_lang("javascript")
    pending "javascript grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "class Counter { count = 0; name = 'test'; }\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.js")
    fields = items.select { |i| i.kind == "field" }
    fields.map(&.name).should contain("count")
    fields.map(&.name).should contain("name")
  end
end

describe Chiasmus::Discovery::PythonExtractor do
  it "extracts class body assignments as fields" do
    extractor = Chiasmus::Discovery::PythonExtractor.new
    lang = load_lang("python")
    pending "python grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "class Foo:\n  name = 'test'\n  count = 42\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.py")
    fields = items.select { |i| i.kind == "field" }
    fields.map(&.name).should contain("name")
    fields.map(&.name).should contain("count")
  end
end

describe Chiasmus::Discovery::TypeScriptExtractor do
  it "extracts class public_field_definition" do
    extractor = Chiasmus::Discovery::TypeScriptExtractor.new
    lang = load_lang("typescript")
    pending "typescript grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "class Foo { name: string; count: number; }\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.ts")
    fields = items.select { |i| i.kind == "field" }
    fields.map(&.name).should contain("name")
    fields.map(&.name).should contain("count")
  end
end
