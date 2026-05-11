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
        @extensions = [".tl"],
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

    class TestAdapterFactory < AdapterFactory
      getter build_count = 0

      def build(descriptor : AdapterDescriptor) : LanguageAdapter?
        @build_count += 1
        TestAdapter.new(
          descriptor.language,
          descriptor.extensions,
          descriptor.grammar_language,
          descriptor.search_paths
        )
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
        AdapterRegistry.clear_adapter_factories
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

        AdapterRegistry.get_adapter_for_ext(".tl").should be(adapter)
        AdapterRegistry.get_adapter_for_ext(".TL").should be(adapter)
        AdapterRegistry.get_adapter_for_ext("tl").should be(adapter)
        AdapterRegistry.get_adapter_for_ext(".xyz").should be_nil
      end

      it "lists adapter extensions" do
        AdapterRegistry.register_adapter(TestAdapter.new)

        AdapterRegistry.adapter_extensions.should eq([".tl"])
      end

      it "accepts adapters with search paths" do
        adapter = TestAdapter.new
        AdapterRegistry.register_adapter(adapter)

        AdapterRegistry.get_adapter("test-lang").not_nil!.search_paths.should eq(["/nonexistent/path"])
      end

      it "clears registrations" do
        AdapterRegistry.register_adapter(TestAdapter.new)

        AdapterRegistry.clear_adapters

        AdapterRegistry.get_adapter("test-lang").should be_nil
        AdapterRegistry.adapter_extensions.should be_empty
      end

      it "keeps discovery idempotent and non-throwing" do
        AdapterRegistry.discover_adapters
        AdapterRegistry.register_adapter(TestAdapter.new)
        AdapterRegistry.discover_adapters

        AdapterRegistry.get_adapter("test-lang").should_not be_nil
      end

      it "discovers adapters from a manifest through a registered factory" do
        Chiasmus::Graph.with_temp_dir("chiasmus-adapters") do |dir|
          manifest_path = File.join(dir, "chiasmus.adapters.json")
          File.write(manifest_path, {
            "adapters" => [
              {
                "language"         => "manifest-lang",
                "extensions"       => [".mf", "MF2"],
                "grammar_language" => "javascript",
                "entrypoint"       => "test-adapter",
                "search_paths"     => [File.join(dir, "nested")],
              },
            ],
          }.to_json)

          factory = TestAdapterFactory.new
          diagnostics = [] of String
          AdapterRegistry.register_adapter_factory("test-adapter", factory)
          AdapterRegistry.discover_adapters([manifest_path], diagnostics)

          AdapterRegistry.get_adapter("manifest-lang").should_not be_nil
          AdapterRegistry.language_for_ext(".mf").should eq("manifest-lang")
          AdapterRegistry.language_for_ext("mf2").should eq("manifest-lang")
          AdapterRegistry.grammar_language_for_ext(".mf").should eq("javascript")
          AdapterRegistry.get_adapter("manifest-lang").not_nil!.search_paths.should eq([File.join(dir, "nested")])
          diagnostics.should be_empty
          factory.build_count.should eq(1)
        end
      end

      it "skips invalid manifest descriptors without throwing" do
        Chiasmus::Graph.with_temp_dir("chiasmus-adapters") do |dir|
          manifest_path = File.join(dir, "chiasmus.adapters.json")
          File.write(manifest_path, {
            "adapters" => [
              {"language" => "missing-extensions", "entrypoint" => "test-adapter"},
              {"language" => "missing-factory", "extensions" => [".mf"], "entrypoint" => "missing"},
            ],
          }.to_json)

          diagnostics = [] of String
          AdapterRegistry.register_adapter_factory("test-adapter", TestAdapterFactory.new)

          AdapterRegistry.discover_adapters([manifest_path], diagnostics)

          AdapterRegistry.get_adapter("missing-extensions").should be_nil
          AdapterRegistry.get_adapter("missing-factory").should be_nil
          diagnostics.size.should eq(2)
        end
      end

      it "runs manifest discovery only once" do
        Chiasmus::Graph.with_temp_dir("chiasmus-adapters") do |dir|
          manifest_path = File.join(dir, "chiasmus.adapters.json")
          File.write(manifest_path, {
            "adapters" => [
              {
                "language"   => "manifest-lang",
                "extensions" => [".mf"],
                "entrypoint" => "test-adapter",
              },
            ],
          }.to_json)

          factory = TestAdapterFactory.new
          AdapterRegistry.register_adapter_factory("test-adapter", factory)

          AdapterRegistry.discover_adapters([manifest_path])
          AdapterRegistry.discover_adapters([manifest_path])

          factory.build_count.should eq(1)
          AdapterRegistry.adapter_extensions.should contain(".mf")
        end
      end

      it "follows discovered adapter search paths for additional manifests" do
        Chiasmus::Graph.with_temp_dir("chiasmus-adapters") do |dir|
          nested_dir = File.join(dir, "nested")
          Dir.mkdir_p(nested_dir)

          manifest_path = File.join(dir, "chiasmus.adapters.json")
          File.write(manifest_path, {
            "adapters" => [
              {
                "language"     => "manifest-lang",
                "extensions"   => [".mf"],
                "entrypoint"   => "test-adapter",
                "search_paths" => [nested_dir],
              },
            ],
          }.to_json)

          nested_manifest_path = File.join(nested_dir, "extra.adapters.json")
          File.write(nested_manifest_path, {
            "adapters" => [
              {
                "language"   => "extra-lang",
                "extensions" => [".extra"],
                "entrypoint" => "test-adapter",
              },
            ],
          }.to_json)

          factory = TestAdapterFactory.new
          AdapterRegistry.register_adapter_factory("test-adapter", factory)

          AdapterRegistry.discover_adapters([manifest_path])

          AdapterRegistry.language_for_ext(".mf").should eq("manifest-lang")
          AdapterRegistry.language_for_ext(".extra").should eq("extra-lang")
          factory.build_count.should eq(2)
        end
      end
    end

    describe Parser do
      before_each do
        AdapterRegistry.clear_adapters
      end

      it "resolves adapter extensions for language lookup" do
        AdapterRegistry.register_adapter(TestAdapter.new)

        Parser.get_language_for_file("foo.tl").should eq("test-lang")
      end

      it "keeps built-in extensions ahead of adapters" do
        AdapterRegistry.register_adapter(TestAdapter.new)

        Parser.get_language_for_file("foo.ts").should eq("typescript")
      end

      it "includes adapter extensions in supported extensions" do
        AdapterRegistry.register_adapter(TestAdapter.new)

        exts = Parser.supported_extensions
        exts.should contain(".tl")
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
            path: "test.tl",
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
          SourceFile.new(path: "a.tl", content: "function a() { shared(); }"),
          SourceFile.new(path: "b.tl", content: "function b() { shared(); }"),
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
          [SourceFile.new(path: "virtual.tl", content: source)],
          FakeParserClient.new("test-lang", tree)
        )

        graph.defines.map(&.name).should contain("alpha")
        graph.calls.map { |call| "#{call.caller}->#{call.callee}" }.should contain("alpha->beta")
      end
    end
  end
end
