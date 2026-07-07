require "spec"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/extractor"
require "tree-sitter-manager"

describe "Java extractor" do
  before_all do
    unless TreeSitterManager::GrammarLoader.tree_sitter_available?("java")
      pending "java tree-sitter grammar not available"
    end
  end

  it "extracts class declarations" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new("test.java", <<-JAVA
        class Calculator {
            int add(int a, int b) {
                return a + b;
            }
        }
      JAVA
      ),
    ])

    names = graph.defines.map(&.name)
    names.should contain("Calculator")

    calc = graph.defines.find { |defn| defn.name == "Calculator" }
    calc.should_not be_nil
    clc = calc || raise "Expected calc"
    clc.kind.should eq(Chiasmus::Graph::SymbolKind::Class)
  end

  it "extracts methods with contains" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new("test.java", <<-JAVA
        class Calc {
            int add(int a, int b) {
                return a + b;
            }

            static int multiply(int a, int b) {
                return a * b;
            }
        }
      JAVA
      ),
    ])

    methods = graph.defines.select { |defn| defn.kind == Chiasmus::Graph::SymbolKind::Method }
    method_names = methods.map(&.name)
    method_names.should contain("add")
    method_names.should contain("multiply")

    contains_pairs = graph.contains.map { |contain_fact| "#{contain_fact.parent}->#{contain_fact.child}" }
    contains_pairs.should contain("Calc->add")
    contains_pairs.should contain("Calc->multiply")
  end

  it "extracts interface declarations" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new("test.java", <<-JAVA
        interface Service {
            void execute();
        }
      JAVA
      ),
    ])

    iface = graph.defines.find { |defn| defn.name == "Service" }
    iface.should_not be_nil
    ifc = iface || raise "Expected iface"
    ifc.kind.should eq(Chiasmus::Graph::SymbolKind::Interface)
  end

  it "extracts call relationships" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new("test.java", <<-JAVA
        class App {
            String greet(String name) {
                return format(name);
            }

            String format(String s) {
                return s.trim();
            }
        }
      JAVA
      ),
    ])

    call_pairs = graph.calls.map { |call_fact| "#{call_fact.caller}->#{call_fact.callee}" }
    call_pairs.should contain("greet->format")
  end

  it "extracts import declarations" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new("test.java", <<-JAVA
        import java.util.List;
        import java.util.ArrayList;
      JAVA
      ),
    ])

    names = graph.imports.map(&.name)
    names.should contain("List")
    names.should contain("ArrayList")

    list_import = graph.imports.find { |i| i.name == "List" }
    list_import.should_not be_nil
    li = list_import || raise "Expected list_import"
    li.source.should eq("java.util.List")
  end

  it "extracts cross-file call graph" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new("Main.java", <<-JAVA
        class Main {
            void run() {
                new Service().handle();
            }
        }
      JAVA
      ),
      Chiasmus::Graph::SourceFile.new("Service.java", <<-JAVA
        class Service {
            void handle() {
                query();
            }

            void query() {}
        }
      JAVA
      ),
    ])

    call_pairs = graph.calls.map { |call_fact| "#{call_fact.caller}->#{call_fact.callee}" }
    call_pairs.should contain("handle->query")
  end

  it "deduplicates call edges" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new("test.java", <<-JAVA
        class A {
            void a() {
                b();
                b();
                b();
            }

            void b() {}
        }
      JAVA
      ),
    ])

    a_to_b = graph.calls.select { |call_fact| call_fact.caller == "a" && call_fact.callee == "b" }
    a_to_b.size.should eq(1)
  end

  it "extracts enum declarations" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new("test.java", <<-JAVA
        enum Color {
            RED,
            GREEN,
            BLUE
        }
      JAVA
      ),
    ])

    color = graph.defines.find { |defn| defn.name == "Color" }
    color.should_not be_nil
    col = color || raise "Expected color"
    col.kind.should eq(Chiasmus::Graph::SymbolKind::Class)
  end
end
