require "spec"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/extractor"
require "tree-sitter-manager"

describe "Rust extractor" do
  before_all do
    unless TreeSitterManager::GrammarLoader.tree_sitter_available?("rust")
      pending "rust tree-sitter grammar not available"
    end
  end

  it "extracts function declarations" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new("test.rs", <<-RUST
        fn handle_request() {}
        fn validate() {}
      RUST
      ),
    ])

    names = graph.defines.map(&.name)
    names.should contain("handle_request")
    names.should contain("validate")
    graph.defines.all? { |defn| defn.kind == Chiasmus::Graph::SymbolKind::Function }.should be_true
  end

  it "extracts struct and enum declarations" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new("test.rs", <<-RUST
        struct Point {
            x: i32,
            y: i32,
        }

        enum Direction {
            North,
            South,
        }
      RUST
      ),
    ])

    names = graph.defines.map(&.name)
    names.should contain("Point")
    names.should contain("Direction")

    point = graph.defines.find { |defn| defn.name == "Point" }
    point.should_not be_nil
    if point
      point.kind.should eq(Chiasmus::Graph::SymbolKind::Class)
    end
  end

  it "extracts impl methods with contains" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new("test.rs", <<-RUST
        struct Point {
            x: i32,
            y: i32,
        }

        impl Point {
            fn new(x: i32, y: i32) -> Self {
                Point { x, y }
            }

            fn distance(&self) -> f64 {
                0.0
            }
        }
      RUST
      ),
    ])

    methods = graph.defines.select { |defn| defn.kind == Chiasmus::Graph::SymbolKind::Method }
    method_names = methods.map(&.name)
    method_names.should contain("new")
    method_names.should contain("distance")

    contains_pairs = graph.contains.map { |child| "#{child.parent}->#{child.child}" }
    contains_pairs.should contain("Point->new")
    contains_pairs.should contain("Point->distance")
  end

  it "extracts trait declarations" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new("test.rs", <<-RUST
        trait Speaker {
            fn speak(&self) -> String;
        }
      RUST
      ),
    ])

    iface = graph.defines.find { |defn| defn.name == "Speaker" }
    iface.should_not be_nil
    if iface
      iface.kind.should eq(Chiasmus::Graph::SymbolKind::Interface)
    end
  end

  it "extracts call relationships" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new("test.rs", <<-RUST
        fn greet(name: &str) -> String {
            helper(name)
        }

        fn helper(s: &str) -> String {
            String::from(s)
        }

        fn main() {
            let s = greet("world");
        }
      RUST
      ),
    ])

    call_pairs = graph.calls.map { |call| "#{call.caller}->#{call.callee}" }
    call_pairs.should contain("greet->helper")
    call_pairs.should contain("main->greet")
  end

  it "extracts use (import) declarations" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new("test.rs", <<-RUST
        use std::collections::HashMap;
        use serde_json::Value;
      RUST
      ),
    ])

    names = graph.imports.map(&.name)
    names.should contain("HashMap")
    names.should contain("Value")

    hashmap_import = graph.imports.find { |entry| entry.name == "HashMap" }
    hashmap_import.should_not be_nil
    if hashmap_import
      hashmap_import.source.should eq("std::collections")
    end
  end

  it "extracts cross-file call graph" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new("main.rs", <<-RUST
        fn main() {
            handle();
        }

        fn handle() {
            query();
        }
      RUST
      ),
      Chiasmus::Graph::SourceFile.new("db.rs", <<-RUST
        fn query() {
            connect();
        }

        fn connect() {}
      RUST
      ),
    ])

    call_pairs = graph.calls.map { |call| "#{call.caller}->#{call.callee}" }
    call_pairs.should contain("main->handle")
    call_pairs.should contain("handle->query")
    call_pairs.should contain("query->connect")
  end

  it "deduplicates call edges" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new("test.rs", <<-RUST
        fn a() {
            b();
            b();
            b();
        }

        fn b() {}
      RUST
      ),
    ])

    a_to_b = graph.calls.select { |call| call.caller == "a" && call.callee == "b" }
    a_to_b.size.should eq(1)
  end

  it "recurses into modules without defining the module name" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new("test.rs", <<-RUST
        mod utils {
            fn helper() {}
        }
      RUST
      ),
    ])

    helper = graph.defines.find { |defn| defn.name == "helper" }
    helper.should_not be_nil
    if helper
      helper.kind.should eq(Chiasmus::Graph::SymbolKind::Function)
    end

    mod_def = graph.defines.find { |defn| defn.name == "utils" }
    mod_def.should be_nil
  end

  it "extracts free functions with signatures" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new("test.rs", <<-RUST
        pub fn add(a: i32, b: i32) -> i32 { a + b }

        fn helper(x: i32) -> i32 { x }
      RUST
      ),
    ])

    add = graph.defines.find { |defn| defn.name == "add" }
    add.should_not be_nil
    if add
      add.kind.should eq(Chiasmus::Graph::SymbolKind::Function)
      add.signature.should eq("(a: i32, b: i32) -> i32")
    end

    helper = graph.defines.find { |defn| defn.name == "helper" }
    helper.should_not be_nil
  end

  it "marks pub items as exported, private items as not" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new("test.rs", <<-RUST
        pub fn public_fn() {}
        fn private_fn() {}
        pub struct Point { x: f64 }
        struct Hidden {}
      RUST
      ),
    ])

    export_names = graph.exports.map(&.name)
    export_names.should contain("public_fn")
    export_names.should contain("Point")
    export_names.should_not contain("private_fn")
    export_names.should_not contain("Hidden")
  end

  it "binds renamed imports to their alias" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new("test.rs", <<-RUST
        use std::io::Result as IoResult;
      RUST
      ),
    ])

    names = graph.imports.map(&.name)
    names.should contain("IoResult")
    names.should_not contain("Result")
  end

  it "attaches trait methods to their trait via contains" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new("test.rs", <<-RUST
        pub trait Shape {
            fn area(&self) -> f64;
        }
      RUST
      ),
    ])

    area = graph.defines.find { |defn| defn.name == "area" }
    area.should_not be_nil
    if area
      area.kind.should eq(Chiasmus::Graph::SymbolKind::Method)
    end
    graph.contains.should contain(Chiasmus::Graph::ContainsFact.new(parent: "Shape", child: "area"))
  end

  it "does not define the impl type itself as a class" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new("test.rs", <<-RUST
        struct Point { x: f64, y: f64 }

        impl Point {
            pub fn area(&self) -> f64 { self.x.hypot(self.y) }
        }
      RUST
      ),
    ])

    area = graph.defines.find { |defn| defn.name == "area" }
    area.should_not be_nil
    if area
      area.kind.should eq(Chiasmus::Graph::SymbolKind::Method)
    end

    point_defs = graph.defines.select { |defn| defn.name == "Point" }
    point_defs.size.should eq(1)
    point_defs.first.kind.should eq(Chiasmus::Graph::SymbolKind::Class)
  end

  it "handles method calls (field_expression) in call edges" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new("test.rs", <<-RUST
        pub fn run() {
            obj.process();
        }
      RUST
      ),
    ])
    calls = graph.calls.select { |call| call.caller == "run" }.map(&.callee)
    calls.should contain("process")
  end

  it "handles associated function calls (scoped_identifier)" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new("test.rs", <<-RUST
        pub fn run() {
            Builder::new();
        }
      RUST
      ),
    ])

    calls = graph.calls.select { |call| call.caller == "run" }.map(&.callee)
    calls.should contain("new")
  end
end
