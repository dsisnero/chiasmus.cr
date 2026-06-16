require "../../spec_helper"
require "tree_sitter"

vendor_dir = File.expand_path("../../../grammars", __DIR__)
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

  it "extracts enum_def" do
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    lang = load_lang("crystal")
    pending "crystal grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "enum Color\n  Red\n  Green\n  Blue\nend\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.cr")
    enums = items.select { |i| i.kind == "class" || i.kind == "enum" }
    enums.map(&.name).should contain("Color")
  end

  it "extracts alias (type alias)" do
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    lang = load_lang("crystal")
    pending "crystal grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "alias PInt32 = Pointer(Int32)\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.cr")
    types = items.select { |i| i.kind == "type" }
    types.map(&.name).should contain("PInt32")
  end

  it "extracts macro_def" do
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    lang = load_lang("crystal")
    pending "crystal grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "macro define_method(name, content)\n  def {{name}}\n    {{content}}\n  end\nend\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.cr")
    macros = items.select { |i| i.kind == "macro" }
    macros.map(&.name).should contain("define_method")
  end

  it "extracts constant assignment" do
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    lang = load_lang("crystal")
    pending "crystal grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "VERSION = \"1.0.0\"\nMAX_SIZE = 1024\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.cr")
    consts = items.select { |i| i.kind == "const" }
    consts.map(&.name).should contain("VERSION")
    consts.map(&.name).should contain("MAX_SIZE")
  end

  it "extracts annotation_def" do
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    lang = load_lang("crystal")
    pending "crystal grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "annotation MyAnnotation\nend\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.cr")
    annotations = items.select { |i| i.kind == "annotation" }
    annotations.map(&.name).should contain("MyAnnotation")
  end

  it "extracts instance variables as fields" do
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    lang = load_lang("crystal")
    pending "crystal grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "class Foo\n  @name : String\n  @count : Int32 = 0\nend\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.cr")
    fields = items.select { |i| i.kind == "field" }
    fields.map(&.name).should contain("@name")
    fields.map(&.name).should contain("@count")
  end

  it "extracts class variables as fields" do
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    lang = load_lang("crystal")
    pending "crystal grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "class Foo\n  @@instances = 0\n  @@config = {} of String => String\nend\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.cr")
    fields = items.select { |i| i.kind == "field" }
    fields.map(&.name).should contain("@@instances")
    fields.map(&.name).should contain("@@config")
  end

  it "extracts lib_def" do
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    lang = load_lang("crystal")
    pending "crystal grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "lib LibC\n  fun malloc(size : UInt64) : Void*\nend\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.cr")
    libs = items.select { |i| i.kind == "lib" }
    libs.map(&.name).should contain("LibC")
  end

  it "extracts fun_def inside lib" do
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    lang = load_lang("crystal")
    pending "crystal grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "lib LibC\n  fun malloc(size : UInt64) : Void*\nend\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.cr")
    funs = items.select { |i| i.kind == "function" }
    funs.map(&.name).should contain("malloc")
  end

  it "extracts type_def inside lib" do
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    lang = load_lang("crystal")
    pending "crystal grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "lib LibC\n  type MyType = Void*\nend\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.cr")
    types = items.select { |i| i.kind == "type" }
    types.map(&.name).should contain("MyType")
  end

  it "extracts union_def inside lib" do
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    lang = load_lang("crystal")
    pending "crystal grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "lib LibC\n  union MyUnion\n    x : Int32\n    y : Float64\n  end\nend\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.cr")
    unions = items.select { |i| i.kind == "class" }
    unions.map(&.name).should contain("MyUnion")
  end

  it "extracts c_struct_def inside lib" do
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    lang = load_lang("crystal")
    pending "crystal grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "lib LibC\n  struct MyStruct\n    x : Int32\n    y : Float64\n  end\nend\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.cr")
    structs = items.select { |i| i.kind == "class" }
    structs.map(&.name).should contain("MyStruct")
  end

  it "extracts abstract method def" do
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    lang = load_lang("crystal")
    pending "crystal grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "abstract class Foo\n  abstract def bar(x : Int32) : String\nend\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.cr")
    methods = items.select { |i| i.kind == "method" }
    methods.map(&.name).should contain("Foo.bar")
  end

  it "includes include with generic type" do
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    lang = load_lang("crystal")
    pending "crystal grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "class Foo\n  include Enumerable(Int32)\nend\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.cr")
    includes = items.select { |i| i.kind == "definition.module" }
    includes.map(&.name).should contain("Enumerable")
  end

  it "captures call with constant receiver (class method call)" do
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    lang = load_lang("crystal")
    pending "crystal grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "Foo.bar(1)\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.cr")
    refs = items.select { |i| i.kind == "reference.call_sel" }
    names = refs.map(&.name)
    names.should contain("bar")
  end

  it "captures call with self receiver" do
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    lang = load_lang("crystal")
    pending "crystal grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "class Foo\n  def run\n    self.helper\n  end\nend\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.cr")
    refs = items.select { |i| i.kind == "reference.call_sel" }
    names = refs.map(&.name)
    names.should contain("helper")
  end

  it "captures call with instance_var receiver" do
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    lang = load_lang("crystal")
    pending "crystal grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "@logger.info(\"started\")\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.cr")
    refs = items.select { |i| i.kind == "reference.call_sel" }
    names = refs.map(&.name)
    names.should contain("info")
  end

  it "filters const kind to UPPER_CASE only" do
    extractor = Chiasmus::Discovery::CrystalExtractor.new
    lang = load_lang("crystal")
    pending "crystal grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "MAX = 100\nname = \"test\"\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.cr")
    consts = items.select { |i| i.kind == "const" }
    consts.size.should eq(1)
    consts[0].name.should eq("MAX")
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
