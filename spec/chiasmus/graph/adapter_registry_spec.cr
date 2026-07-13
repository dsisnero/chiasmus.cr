require "spec"
require "json"
require "file_utils"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/adapter_registry"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/extractor"

module Chiasmus
  module Graph
    class TestAdapter < LanguageAdapter
      def initialize(
        @language = "test-lang",
        @extensions = [".testext"],
        @grammar_language = "javascript",
        @search_paths : Array(String)? = ["/nonexistent/path"],
      )
      end

      def language : String
        @language
      end

      def grammar_language : String
        @grammar_language
      end

      def extensions : Array(String)
        @extensions
      end

      def extract(root_node : TreeSitter::Node, source : String, file_path : String) : CodeGraph
        defines = [] of DefinesFact
        calls = [] of CallsFact
        seen = Set(String).new

        root_node.children.each do |child|
          next unless child.type == "function_declaration"

          name = child.child_by_field_name("name").try(&.text(source))
          next unless name

          defines << DefinesFact.new(
            file: file_path,
            name: name,
            kind: SymbolKind::Function,
            line: child.start_point.row.to_i + 1
          )

          walk_calls(child, source, name, calls, seen)
        end

        CodeGraph.new(defines: defines, calls: calls)
      end

      def search_paths : Array(String)?
        @search_paths
      end

      private def walk_calls(node : TreeSitter::Node, source : String, caller : String, calls : Array(CallsFact), seen : Set(String)) : Nil
        node.children.each do |child|
          if child.type == "call_expression"
            fn = child.child_by_field_name("function")
            if fn && fn.type == "identifier"
              callee = fn.text(source)
              key = "#{caller}->#{callee}"
              unless seen.includes?(key)
                seen.add(key)
                calls << CallsFact.new(caller: caller, callee: callee)
              end
            end
          end

          walk_calls(child, source, caller, calls, seen)
        end
      end
    end

    class FakeParserClient
      def initialize(@language : String?, @tree : TreeSitter::Tree?)
      end

      def language_for_file(file_path : String) : String?
        @language
      end

      def parse_source(content : String, file_path : String) : TreeSitter::Tree?
        @tree
      end
    end

    def self.with_temp_dir(prefix : String, & : String -> Nil) : Nil
      dir = File.join(Dir.tempdir, "#{prefix}-#{Random.rand(1_000_000_000)}")
      Dir.mkdir_p(dir)
      yield dir
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    describe AdapterRegistry do
      before_each do
        AdapterRegistry.clear_adapters
      end

      it "registers adapters and resolves them by language" do
        adapter = TestAdapter.new
        AdapterRegistry.register_adapter(adapter)

        AdapterRegistry.get_adapter("test-lang").should be(adapter)
        AdapterRegistry.get_adapter("missing").should be_nil
      end

      it "resolves adapters by normalized extension" do
        adapter = TestAdapter.new
        AdapterRegistry.register_adapter(adapter)

        AdapterRegistry.get_adapter_for_ext(".testext").should be(adapter)
        AdapterRegistry.get_adapter_for_ext(".TESTEXT").should be(adapter)
        AdapterRegistry.get_adapter_for_ext("testext").should be(adapter)
        AdapterRegistry.get_adapter_for_ext(".xyz").should be_nil
      end

      it "lists adapter extensions" do
        AdapterRegistry.register_adapter(TestAdapter.new)

        AdapterRegistry.adapter_extensions.should eq([".testext"])
      end

      it "accepts adapters with search paths" do
        adapter = TestAdapter.new
        AdapterRegistry.register_adapter(adapter)

        resolved = AdapterRegistry.get_adapter("test-lang")
        raise "expected non-nil adapter" if resolved.nil?
        resolved.search_paths.should eq(["/nonexistent/path"])
      end

      it "clears registrations" do
        AdapterRegistry.register_adapter(TestAdapter.new)

        AdapterRegistry.clear_adapters

        AdapterRegistry.get_adapter("test-lang").should be_nil
        AdapterRegistry.adapter_extensions.should be_empty
      end
    end

    describe Parser do
      before_each do
        AdapterRegistry.clear_adapters
      end

      it "resolves adapter extensions for language lookup" do
        AdapterRegistry.register_adapter(TestAdapter.new)

        Parser.get_language_for_file("foo.testext").should eq("test-lang")
      end

      it "keeps built-in extensions ahead of adapters" do
        AdapterRegistry.register_adapter(TestAdapter.new)

        Parser.get_language_for_file("foo.ts").should eq("typescript")
      end

      it "includes adapter extensions in supported extensions" do
        AdapterRegistry.register_adapter(TestAdapter.new)

        exts = Parser.supported_extensions
        exts.should contain(".testext")
        exts.should contain(".ts")
      end
    end

    describe Extractor do
      before_each do
        AdapterRegistry.clear_adapters
      end

      it "dispatches registered adapter extraction" do
        AdapterRegistry.register_adapter(TestAdapter.new)

        graph = Extractor.extract_graph([
          SourceFile.new(
            path: "test.testext",
            content: "function hello() { world(); }\nfunction world() {}"
          ),
        ])

        graph.defines.map(&.name).should contain("hello")
        graph.defines.map(&.name).should contain("world")
        graph.calls.map { |call| "#{call.caller}->#{call.callee}" }.should contain("hello->world")
      end

      it "does not affect built-in language extraction" do
        AdapterRegistry.register_adapter(TestAdapter.new)

        graph = Extractor.extract_graph([
          SourceFile.new(
            path: "test.js",
            content: "function foo() { bar(); }\nfunction bar() {}"
          ),
        ])

        graph.defines.map(&.name).should contain("foo")
        graph.calls.map { |call| "#{call.caller}->#{call.callee}" }.should contain("foo->bar")
      end

      it "keeps calls from separate adapter-extracted files distinct" do
        AdapterRegistry.register_adapter(TestAdapter.new)

        graph = Extractor.extract_graph([
          SourceFile.new(path: "a.testext", content: "function a() { shared(); }"),
          SourceFile.new(path: "b.testext", content: "function b() { shared(); }"),
        ])

        graph.calls.map { |call| "#{call.caller}->#{call.callee}" }.should contain("a->shared")
        graph.calls.map { |call| "#{call.caller}->#{call.callee}" }.should contain("b->shared")
      end

      it "supports parser injection for extractor services" do
        AdapterRegistry.register_adapter(TestAdapter.new)
        source = "function alpha() { beta(); }\nfunction beta() {}"
        tree = Parser.parse_source(source, "test.js")
        tree.should_not be_nil

        graph = Extractor.extract_graph(
          [SourceFile.new(path: "virtual.testext", content: source)],
          FakeParserClient.new("test-lang", tree)
        )

        graph.defines.map(&.name).should contain("alpha")
        graph.calls.map { |call| "#{call.caller}->#{call.callee}" }.should contain("alpha->beta")
      end
    end
  end
end
