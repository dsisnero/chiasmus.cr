require "spec"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/extractor"

describe "Rust extractor" do
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
    graph.defines.all? { |d| d.kind == Chiasmus::Graph::SymbolKind::Function }.should be_true
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

    point = graph.defines.find { |d| d.name == "Point" }
    point.should_not be_nil
    point.not_nil!.kind.should eq(Chiasmus::Graph::SymbolKind::Class)
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

    methods = graph.defines.select { |d| d.kind == Chiasmus::Graph::SymbolKind::Method }
    method_names = methods.map(&.name)
    method_names.should contain("new")
    method_names.should contain("distance")

    contains_pairs = graph.contains.map { |c| "#{c.parent}->#{c.child}" }
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

    iface = graph.defines.find { |d| d.name == "Speaker" }
    iface.should_not be_nil
    iface.not_nil!.kind.should eq(Chiasmus::Graph::SymbolKind::Interface)
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

    call_pairs = graph.calls.map { |c| "#{c.caller}->#{c.callee}" }
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

    hashmap_import = graph.imports.find { |i| i.name == "HashMap" }
    hashmap_import.should_not be_nil
    hashmap_import.not_nil!.source.should eq("std::collections::HashMap")
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

    call_pairs = graph.calls.map { |c| "#{c.caller}->#{c.callee}" }
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

    a_to_b = graph.calls.select { |c| c.caller == "a" && c.callee == "b" }
    a_to_b.size.should eq(1)
  end

  it "extracts module declarations" do
    graph = Chiasmus::Graph::Extractor.extract_graph([
      Chiasmus::Graph::SourceFile.new("test.rs", <<-RUST
        mod utils {
            fn helper() {}
        }
      RUST
      ),
    ])

    mod_def = graph.defines.find { |d| d.name == "utils" }
    mod_def.should_not be_nil
    mod_def.not_nil!.kind.should eq(Chiasmus::Graph::SymbolKind::Interface)
  end
end
