require "spec"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/extractor"
require "../../../src/chiasmus/graph/parser"

describe Chiasmus::Graph::Extractor do
  describe "JavaScript/TypeScript" do
    it "extracts function declarations" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("test.ts", <<-JS
          function handleRequest() {}
          function validate() {}
        JS
        ),
      ])

      names = graph.defines.map(&.name)
      names.should contain("handleRequest")
      names.should contain("validate")
      graph.defines.all? { |d| d.kind == Chiasmus::Graph::SymbolKind::Function }.should be_true
      graph.defines.all? { |d| d.file == "test.ts" }.should be_true
    end

    it "extracts arrow functions assigned to const" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("test.ts", <<-JS
          const processData = (x) => { return x; };
        JS
        ),
      ])

      names = graph.defines.map(&.name)
      names.should contain("processData")
    end

    it "extracts call relationships" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("test.ts", <<-JS
          function a() { b(); c(); }
          function b() { c(); }
          function c() {}
        JS
        ),
      ])

      call_pairs = graph.calls.map { |c| "#{c.caller}->#{c.callee}" }
      call_pairs.should contain("a->b")
      call_pairs.should contain("a->c")
      call_pairs.should contain("b->c")
    end

    it "extracts method calls from member expressions" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("test.ts", <<-JS
          function foo() { this.bar(); obj.baz(); }
          function bar() {}
          function baz() {}
        JS
        ),
      ])

      callees = graph.calls.select { |c| c.caller == "foo" }.map(&.callee)
      callees.should contain("bar")
      callees.should contain("baz")
    end

    it "extracts class with methods and produces defines + contains" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("test.ts", <<-JS
          class MyService {
            handleRequest() {}
            validate() {}
          }
        JS
        ),
      ])

      class_define = graph.defines.find { |d| d.name == "MyService" }
      class_define.should_not be_nil
      class_define.not_nil!.kind.should eq(Chiasmus::Graph::SymbolKind::Class)

      methods = graph.defines.select { |d| d.kind == Chiasmus::Graph::SymbolKind::Method }
      method_names = methods.map(&.name)
      method_names.should contain("handleRequest")
      method_names.should contain("validate")

      contains_pairs = graph.contains.map { |c| "#{c.parent}->#{c.child}" }
      contains_pairs.should contain("MyService->handleRequest")
      contains_pairs.should contain("MyService->validate")
    end

    it "extracts import statements" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("test.ts", "import { query, validate } from './db';"),
      ])

      graph.imports.size.should eq(2)
      names = graph.imports.map(&.name)
      names.should contain("query")
      names.should contain("validate")
      graph.imports.all? { |i| i.source == "./db" }.should be_true
    end

    it "extracts export statements" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("test.ts", <<-JS
          export function main() {}
          export { helper };
        JS
        ),
      ])

      export_names = graph.exports.map(&.name)
      export_names.should contain("main")
      export_names.should contain("helper")
    end

    it "combines facts across multiple files" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("server.ts", <<-JS
          import { query } from './db';
          export function handleRequest() { query(); }
        JS
        ),
        Chiasmus::Graph::SourceFile.new("db.ts", <<-JS
          export function query() { connect(); }
          function connect() {}
        JS
        ),
      ])

      call_pairs = graph.calls.map { |c| "#{c.caller}->#{c.callee}" }
      call_pairs.should contain("handleRequest->query")
      call_pairs.should contain("query->connect")

      graph.imports.any? { |i| i.name == "query" && i.source == "./db" }.should be_true

      export_names = graph.exports.map(&.name)
      export_names.should contain("handleRequest")
      export_names.should contain("query")
    end

    it "deduplicates call edges" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("test.ts", <<-JS
          function a() { b(); b(); b(); }
          function b() {}
        JS
        ),
      ])

      a_to_b_calls = graph.calls.select { |c| c.caller == "a" && c.callee == "b" }
      a_to_b_calls.size.should eq(1)
    end

    it "skips unsupported file extensions" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("test.rb", <<-RUBY
          def hello; puts "hi"; end
        RUBY
        ),
      ])

      graph.defines.size.should eq(0)
      graph.calls.size.should eq(0)
    end
  end

  describe "Python" do
    it "extracts function definitions" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("test.py", <<-PY
          def handle_request():
              pass

          def validate():
              pass
        PY
        ),
      ])

      names = graph.defines.map(&.name)
      names.should contain("handle_request")
      names.should contain("validate")
      graph.defines.all? { |d| d.kind == Chiasmus::Graph::SymbolKind::Function }.should be_true
    end

    it "extracts class with methods and contains" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("test.py", <<-PY
          class Animal:
              def __init__(self, name):
                  self.name = name

              def speak(self):
                  return self.name
        PY
        ),
      ])

      class_def = graph.defines.find { |d| d.name == "Animal" }
      class_def.should_not be_nil
      class_def.not_nil!.kind.should eq(Chiasmus::Graph::SymbolKind::Class)

      methods = graph.defines.select { |d| d.kind == Chiasmus::Graph::SymbolKind::Method }
      method_names = methods.map(&.name)
      method_names.should contain("__init__")
      method_names.should contain("speak")

      contains_pairs = graph.contains.map { |c| "#{c.parent}->#{c.child}" }
      contains_pairs.should contain("Animal->__init__")
      contains_pairs.should contain("Animal->speak")
    end

    it "extracts call relationships" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("test.py", <<-PY
          def greet(name):
              return format_name(name)

          def format_name(name):
              return name.strip()

          def main():
              print(greet("hi"))
        PY
        ),
      ])

      call_pairs = graph.calls.map { |c| "#{c.caller}->#{c.callee}" }
      call_pairs.should contain("greet->format_name")
      call_pairs.should contain("main->print")
      call_pairs.should contain("main->greet")
    end

    it "extracts method calls via attribute access" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("test.py", <<-PY
          class Dog:
              def speak(self):
                  return self.greet("woof")

              def greet(self, sound):
                  return format(sound)
        PY
        ),
      ])

      callees = graph.calls.select { |c| c.caller == "speak" }.map(&.callee)
      callees.should contain("greet")
    end

    it "extracts import statements" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("test.py", <<-PY
          import os
          from pathlib import Path
          from collections import defaultdict as dd
        PY
        ),
      ])

      names = graph.imports.map(&.name)
      names.should contain("os")
      names.should contain("Path")
      names.should contain("dd")

      path_import = graph.imports.find { |i| i.name == "Path" }
      path_import.should_not be_nil
      path_import.not_nil!.source.should eq("pathlib")
    end

    it "extracts cross-file call graph" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("app.py", <<-PY
          from db import query

          def handle():
              query()
        PY
        ),
        Chiasmus::Graph::SourceFile.new("db.py", <<-PY
          def query():
              connect()

          def connect():
              pass
        PY
        ),
      ])

      call_pairs = graph.calls.map { |c| "#{c.caller}->#{c.callee}" }
      call_pairs.should contain("handle->query")
      call_pairs.should contain("query->connect")
    end

    it "deduplicates call edges" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("test.py", <<-PY
          def a():
              b()
              b()
              b()

          def b():
              pass
        PY
        ),
      ])

      a_to_b_calls = graph.calls.select { |c| c.caller == "a" && c.callee == "b" }
      a_to_b_calls.size.should eq(1)
    end

    it "nested functions inside functions are kind=function not method" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("test.py", <<-PY
          def outer():
              def inner():
                  pass
              inner()
        PY
        ),
      ])

      inner = graph.defines.find { |d| d.name == "inner" }
      inner.should_not be_nil
      inner.not_nil!.kind.should eq(Chiasmus::Graph::SymbolKind::Function)
    end

    it "extracts multiple imports from a single from-import statement" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("test.py", "from foo import a, b, c"),
      ])

      names = graph.imports.map(&.name)
      names.should contain("a")
      names.should contain("b")
      names.should contain("c")
      graph.imports.all? { |i| i.source == "foo" }.should be_true
    end
  end

  describe "Go" do
    it "extracts function declarations" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("test.go", <<-GO
          package main

          func handleRequest() {}
          func validate() {}
        GO
        ),
      ])

      names = graph.defines.map(&.name)
      names.should contain("handleRequest")
      names.should contain("validate")
      graph.defines.all? { |d| d.kind == Chiasmus::Graph::SymbolKind::Function }.should be_true
    end

    it "extracts methods with receiver type and contains" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("test.go", <<-GO
          package main

          type Animal struct {
              Name string
          }

          func (a *Animal) Speak() string {
              return a.Name
          }

          func (a Animal) Greet() string {
              return "hi"
          }
        GO
        ),
      ])

      struct_def = graph.defines.find { |d| d.name == "Animal" }
      struct_def.should_not be_nil
      struct_def.not_nil!.kind.should eq(Chiasmus::Graph::SymbolKind::Class)

      methods = graph.defines.select { |d| d.kind == Chiasmus::Graph::SymbolKind::Method }
      method_names = methods.map(&.name)
      method_names.should contain("Speak")
      method_names.should contain("Greet")

      contains_pairs = graph.contains.map { |c| "#{c.parent}->#{c.child}" }
      contains_pairs.should contain("Animal->Speak")
      contains_pairs.should contain("Animal->Greet")
    end

    it "extracts call relationships" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("test.go", <<-GO
          package main

          import "fmt"

          func greet(name string) string {
              return fmt.Sprintf("Hello %s", name)
          }

          func main() {
              fmt.Println(greet("world"))
          }
        GO
        ),
      ])

      call_pairs = graph.calls.map { |c| "#{c.caller}->#{c.callee}" }
      call_pairs.should contain("greet->Sprintf")
      call_pairs.should contain("main->Println")
      call_pairs.should contain("main->greet")
    end

    it "extracts interface definitions" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("test.go", <<-GO
          package main

          type Speaker interface {
              Speak() string
          }
        GO
        ),
      ])

      iface = graph.defines.find { |d| d.name == "Speaker" }
      iface.should_not be_nil
      iface.not_nil!.kind.should eq(Chiasmus::Graph::SymbolKind::Interface)
    end

    it "extracts import declarations" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("test.go", <<-GO
          package main

          import (
              "fmt"
              "strings"
          )
        GO
        ),
      ])

      names = graph.imports.map(&.name)
      names.should contain("fmt")
      names.should contain("strings")
    end

    it "exports uppercase symbols only" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("test.go", <<-GO
          package main

          func Exported() {}
          func unexported() {}

          type MyStruct struct {}
          type myPrivate struct {}
        GO
        ),
      ])

      export_names = graph.exports.map(&.name)
      export_names.should contain("Exported")
      export_names.should contain("MyStruct")
      export_names.should_not contain("unexported")
      export_names.should_not contain("myPrivate")
    end

    it "extracts cross-file call graph" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("main.go", <<-GO
          package main

          func main() {
              Handle()
          }

          func Handle() {
              Query()
          }
        GO
        ),
        Chiasmus::Graph::SourceFile.new("db.go", <<-GO
          package main

          func Query() {
              connect()
          }

          func connect() {}
        GO
        ),
      ])

      call_pairs = graph.calls.map { |c| "#{c.caller}->#{c.callee}" }
      call_pairs.should contain("main->Handle")
      call_pairs.should contain("Handle->Query")
      call_pairs.should contain("Query->connect")
    end

    it "deduplicates call edges" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("test.go", <<-GO
          package main

          func a() {
              b()
              b()
              b()
          }

          func b() {}
        GO
        ),
      ])

      a_to_b = graph.calls.select { |c| c.caller == "a" && c.callee == "b" }
      a_to_b.size.should eq(1)
    end

    it "does not export underscore-prefixed or lowercase identifiers" do
      graph = Chiasmus::Graph::Extractor.extract_graph([
        Chiasmus::Graph::SourceFile.new("test.go", <<-GO
          package main

          func _helper() {}
          type _internal struct {}
        GO
        ),
      ])

      graph.exports.size.should eq(0)
    end
  end
end
