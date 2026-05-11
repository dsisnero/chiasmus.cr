require "../../spec_helper"
require "tree_sitter"

# Grammar initialization
vendor_dir = File.expand_path("../../../vendor/grammars", __DIR__)
if Dir.exists?(vendor_dir)
  Chiasmus::Discovery.register_grammar_directory(vendor_dir)
end

private def load_grammar(language : String, grammar_dir : String) : TreeSitter::Language
  Chiasmus::Discovery.load_language(grammar_dir) || (pending "grammar not available"; next)
end

describe Chiasmus::Discovery::PythonExtractor do
  it "extracts class definitions" do
    extractor = Chiasmus::Discovery::PythonExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("python")
    pending "python grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    tree = parser.parse(nil, "class MyClass:\n  pass\n")

    items = extractor.extract(tree.root_node, tree.root_node.text("class MyClass:\n  pass\n"), "test.py")
    classes = items.select { |i| i.kind == "class" }
    classes.map(&.name).should contain("MyClass")
  end

  it "extracts function definitions" do
    extractor = Chiasmus::Discovery::PythonExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("python")
    pending "python grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "def my_func():\n  pass\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.py")
    functions = items.select { |i| i.kind == "function" }
    functions.map(&.name).should contain("my_func")
  end

  it "extracts UPPERCASE constants" do
    extractor = Chiasmus::Discovery::PythonExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("python")
    pending "python grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "API_KEY = 'secret'\nnormal_var = 1\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.py")
    consts = items.select { |i| i.kind == "const" }
    consts.map(&.name).should contain("API_KEY")
    consts.map(&.name).should_not contain("normal_var")
  end

  it "extracts test functions named test_*" do
    extractor = Chiasmus::Discovery::PythonExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("python")
    pending "python grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "def test_addition():\n  pass\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.py")
    tests = items.select { |i| i.scope == "test" }
    tests.map(&.name).should contain("test_addition")
  end

  it "classifies methods inside classes as method kind" do
    extractor = Chiasmus::Discovery::PythonExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("python")
    pending "python grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "class Foo:\n  def bar(self):\n    pass\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.py")
    methods = items.select { |i| i.kind == "method" }
    methods.map(&.name).should contain("Foo.bar")
  end
end

describe Chiasmus::Discovery::GoExtractor do
  it "extracts function declarations" do
    extractor = Chiasmus::Discovery::GoExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("go")
    pending "go grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "package main\nfunc main() {}\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.go")
    functions = items.select { |i| i.kind == "function" }
    functions.map(&.name).should contain("main")
  end

  it "extracts struct as class" do
    extractor = Chiasmus::Discovery::GoExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("go")
    pending "go grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "package main\ntype Server struct {}\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.go")
    classes = items.select { |i| i.kind == "class" }
    classes.map(&.name).should contain("Server")
  end

  it "extracts interface as interface" do
    extractor = Chiasmus::Discovery::GoExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("go")
    pending "go grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "package main\ntype Speaker interface {}\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.go")
    interfaces = items.select { |i| i.kind == "interface" }
    interfaces.map(&.name).should contain("Speaker")
  end

  it "extracts methods with receiver-qualified names" do
    extractor = Chiasmus::Discovery::GoExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("go")
    pending "go grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "package main\nfunc (s *Server) Start() {}\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.go")
    methods = items.select { |i| i.kind == "method" }
    methods.map(&.name).should contain("Server.Start")
  end

  it "extracts TestXxx functions as tests" do
    extractor = Chiasmus::Discovery::GoExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("go")
    pending "go grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "package main\nfunc TestServer(t *testing.T) {}\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.go")
    tests = items.select { |i| i.scope == "test" }
    tests.map(&.name).should contain("TestServer")
  end
end

describe Chiasmus::Discovery::JavaExtractor do
  it "extracts class declarations" do
    extractor = Chiasmus::Discovery::JavaExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("java")
    pending "java grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "class MyClass {}\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.java")
    classes = items.select { |i| i.kind == "class" }
    classes.map(&.name).should contain("MyClass")
  end

  it "extracts interface declarations" do
    extractor = Chiasmus::Discovery::JavaExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("java")
    pending "java grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "interface Runnable {}\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.java")
    interfaces = items.select { |i| i.kind == "interface" }
    interfaces.map(&.name).should contain("Runnable")
  end

  it "extracts enum declarations as class" do
    extractor = Chiasmus::Discovery::JavaExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("java")
    pending "java grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "enum Color { RED, GREEN }\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.java")
    classes = items.select { |i| i.kind == "class" }
    classes.map(&.name).should contain("Color")
  end

  it "extracts method declarations" do
    extractor = Chiasmus::Discovery::JavaExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("java")
    pending "java grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "class X { void foo() {} }\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.java")
    methods = items.select { |i| i.kind == "method" }
    methods.map(&.name).should contain("X.foo")
  end
end

describe Chiasmus::Discovery::RustExtractor do
  it "extracts struct_item as class" do
    extractor = Chiasmus::Discovery::RustExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("rust")
    pending "rust grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "struct Point { x: i32 }\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.rs")
    classes = items.select { |i| i.kind == "class" }
    classes.map(&.name).should contain("Point")
  end

  it "extracts enum_item as class" do
    extractor = Chiasmus::Discovery::RustExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("rust")
    pending "rust grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "enum Option { Some, None }\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.rs")
    classes = items.select { |i| i.kind == "class" }
    classes.map(&.name).should contain("Option")
  end

  it "extracts trait_item as interface" do
    extractor = Chiasmus::Discovery::RustExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("rust")
    pending "rust grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "trait Display {}\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.rs")
    interfaces = items.select { |i| i.kind == "interface" }
    interfaces.map(&.name).should contain("Display")
  end

  it "extracts function_item" do
    extractor = Chiasmus::Discovery::RustExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("rust")
    pending "rust grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "fn main() {}\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.rs")
    functions = items.select { |i| i.kind == "function" }
    functions.map(&.name).should contain("main")
  end

  it "extracts UPPERCASE const_item" do
    extractor = Chiasmus::Discovery::RustExtractor.new
    lang = Chiasmus::Discovery::GrammarLoader.load_language("rust")
    pending "rust grammar not available" unless lang
    parser = TreeSitter::Parser.new(language: lang)
    source = "const MAX: i32 = 100;\n"
    tree = parser.parse(nil, source)

    items = extractor.extract(tree.root_node, source, "test.rs")
    consts = items.select { |i| i.kind == "const" }
    consts.map(&.name).should contain("MAX")
  end
end
