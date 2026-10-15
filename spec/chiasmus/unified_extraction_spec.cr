require "spec"
require "../../src/chiasmus/graph/extractor"

class CountingJavaParser
  getter parse_count = 0

  def language_for_file(file_path : String) : String?
    Chiasmus::Graph::Parser.language_for_file(file_path)
  end

  def parse_source(content : String, file_path : String) : TreeSitter::Tree?
    @parse_count += 1
    Chiasmus::Graph::Parser.parse_source(content, file_path)
  end
end

describe Chiasmus::Graph::Extractor do
  it "collects facts and typed declarations from one parse per file" do
    file = Chiasmus::Graph::SourceFile.new("Greeter.java", "class Greeter { void greet() {} }")
    parser = CountingJavaParser.new
    typed_results = [] of Chiasmus::Graph::FileExtraction::Result

    graph = Chiasmus::Graph::Extractor.extract_graph([file], parser, typed_results: typed_results)

    parser.parse_count.should eq(1)
    graph.defines.map(&.name).should contain("greet")
    typed_results.size.should eq(1)
    typed_results.first.declarations.map(&.name).should contain("greet")
  end

  it "reuses typed extraction on a warm facts cache and reparses an edit once" do
    dir = File.join(Dir.tempdir, "chiasmus-typed-graph-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      path = File.join(dir, "Greeter.java")
      cache_dir = File.join(dir, "cache")
      parser = CountingJavaParser.new
      old_file = Chiasmus::Graph::SourceFile.new(path, "class Greeter { void greet() {} }")
      edited_file = Chiasmus::Graph::SourceFile.new(path, "class Greeter { void wave() {} }")
      typed_results = [] of Chiasmus::Graph::FileExtraction::Result

      Chiasmus::Graph::Extractor.extract_graph([old_file], parser, cache_dir: cache_dir, typed_results: typed_results)
      Chiasmus::Graph::Extractor.extract_graph([old_file], parser, cache_dir: cache_dir, typed_results: typed_results)
      parser.parse_count.should eq(1)
      typed_results.size.should eq(2)
      typed_results.last.declarations.map(&.name).should contain("greet")

      typed_results.clear
      graph = Chiasmus::Graph::Extractor.extract_graph([edited_file], parser, cache_dir: cache_dir, typed_results: typed_results)
      parser.parse_count.should eq(2)
      graph.defines.map(&.name).should contain("wave")
      typed_results.first.declarations.map(&.name).should contain("wave")
    ensure
      Chiasmus::Graph::GraphCache.flush_async_writes
      Chiasmus::Graph::GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(dir)
    end
  end

  it "runs graph and discovery extraction from one Java parse tree" do
    source = <<-JAVA
      class Greeter {
        void greet() {}
      }
      JAVA
    file = Chiasmus::Graph::SourceFile.new("Greeter.java", source)
    parser = CountingJavaParser.new

    result = Chiasmus::Graph::Extractor.extract_with_discovery(file, "java", parser)
    combined = result || raise "expected combined extraction result"

    parser.parse_count.should eq(1)
    combined.graph.defines.map(&.name).should contain("Greeter")
    combined.discovery.items.map(&.name).should contain("Greeter")
    combined.discovery.items.map(&.name).should contain("greet")
  end

  it "retains Java declaration kinds and typed API fields beside legacy projections" do
    source = <<-JAVA
      package demo.api;
      public class Greeter extends BaseGreeter {
        private int count;
        public static final int LIMIT = 4;
        public Greeter(int initial) {}
        protected static String greet(String name) { return name; }
      }
      enum Mode { FAST, SLOW }
      JAVA
    file = Chiasmus::Graph::SourceFile.new("Greeter.java", source)
    result = Chiasmus::Graph::Extractor.extract_with_discovery(file, "java") || raise "expected extraction"
    declarations = result.typed.declarations

    greeter = declarations.find { |declaration| declaration.name == "Greeter" && declaration.kind == "class" } || raise "missing class"
    greeter.namespace.should eq("demo.api")
    greeter.visibility.should eq("public")
    (greeter.base_types || raise "missing base types").should contain("extends BaseGreeter")

    field = declarations.find { |declaration| declaration.name == "count" } || raise "missing field"
    field.kind.should eq("field")
    field.owner.should eq("Greeter")
    field.visibility.should eq("private")
    field.mutable.should be_true
    declarations.find { |declaration| declaration.name == "LIMIT" }.try(&.kind).should eq("constant")

    constructor = declarations.find { |declaration| declaration.kind == "constructor" } || raise "missing constructor"
    constructor.parameters.try(&.map(&.name)).should eq(["initial"])
    method = declarations.find { |declaration| declaration.name == "greet" } || raise "missing method"
    method.parameters.try(&.map(&.type_name)).should eq(["String"])
    method.return_type.should eq("String")
    method.static.should be_true
    method.visibility.should eq("protected")
    declarations.find { |declaration| declaration.name == "FAST" }.try(&.kind).should eq("enum_constant")

    result.graph.defines.map(&.name).should contain("greet")
    result.discovery.items.map(&.name).should contain("greet")
  end

  it "assigns stable local IDs to Java overloads and movable occurrences" do
    source = "class Greeter { void greet(String value) {} void greet(int value) {} }"
    first = Chiasmus::Graph::Extractor.extract_with_discovery(Chiasmus::Graph::SourceFile.new("src/Greeter.java", source), "java") || raise "missing first extraction"
    shifted = Chiasmus::Graph::Extractor.extract_with_discovery(Chiasmus::Graph::SourceFile.new("src/Greeter.java", "\n\n#{source}"), "java") || raise "missing shifted extraction"
    methods = first.typed.declarations.select { |declaration| declaration.name == "greet" }
    shifted_methods = shifted.typed.declarations.select { |declaration| declaration.name == "greet" }

    methods.size.should eq(2)
    methods.map(&.declaration_id).uniq.size.should eq(2)
    methods.map(&.declaration_id).should eq(shifted_methods.map(&.declaration_id))
    methods.map(&.occurrence_id).should_not eq(shifted_methods.map(&.occurrence_id))
    methods.all? { |declaration| declaration.declaration_id.try(&.starts_with?("decl:v1:")) }.should be_true
    methods.all? { |declaration| declaration.occurrence_id.try(&.starts_with?("occ:v1:")) }.should be_true
  end

  it "applies Java interface implicit modifiers to typed declarations" do
    source = "interface Service { int LIMIT = 4; void run(); }"
    result = Chiasmus::Graph::Extractor.extract_with_discovery(Chiasmus::Graph::SourceFile.new("Service.java", source), "java") || raise "missing extraction"
    limit = result.typed.declarations.find { |declaration| declaration.name == "LIMIT" } || raise "missing constant"
    run = result.typed.declarations.find { |declaration| declaration.name == "run" } || raise "missing method"
    limit.kind.should eq("constant")
    limit.static.should be_true
    limit.mutable.should be_false
    limit.visibility.should eq("public")
    run.visibility.should eq("public")
    run.abstract.should be_true
  end

  it "distinguishes grouped Go constants and types in typed declarations" do
    source = <<-GO
      package demo

      const (
        DefaultLimit = 12
        MaxLimit = DefaultLimit * 2
      )

      type (
        Widget struct { Name string }
        Named interface { Label() string }
      )
      GO
    result = Chiasmus::Graph::Extractor.extract_with_discovery(Chiasmus::Graph::SourceFile.new("model.go", source), "go") || raise "missing extraction"
    declarations = result.typed.declarations

    default_limit = declarations.find { |declaration| declaration.name == "DefaultLimit" } || raise "missing grouped constant"
    max_limit = declarations.find { |declaration| declaration.name == "MaxLimit" } || raise "missing second grouped constant"
    widget = declarations.find { |declaration| declaration.name == "Widget" } || raise "missing grouped struct type"
    named = declarations.find { |declaration| declaration.name == "Named" } || raise "missing grouped interface type"

    default_limit.kind.should eq("constant")
    max_limit.kind.should eq("constant")
    widget.kind.should eq("class")
    named.kind.should eq("interface")
    [default_limit, max_limit, widget, named].each do |declaration|
      declaration.namespace.should eq("demo")
      declaration.extraction_method.should eq("tree_sitter_ast")
    end
  end

  it "extracts Go receiver methods with structured signatures and stable declaration IDs" do
    source = <<-GO
      package demo

      type Animal struct{}

      func (a *Animal) Speak(prefix string, times int) string {
        return prefix
      }
      GO
    shifted_source = "\n\n#{source}"
    first = Chiasmus::Graph::Extractor.extract_with_discovery(Chiasmus::Graph::SourceFile.new("src/animal.go", source), "go") || raise "missing first extraction"
    shifted = Chiasmus::Graph::Extractor.extract_with_discovery(Chiasmus::Graph::SourceFile.new("src/animal.go", shifted_source), "go") || raise "missing shifted extraction"
    method = first.typed.declarations.find { |declaration| declaration.name == "Speak" } || raise "missing receiver method"
    shifted_method = shifted.typed.declarations.find { |declaration| declaration.name == "Speak" } || raise "missing shifted receiver method"

    method.kind.should eq("method")
    method.owner.should eq("Animal")
    method.qualified_name.should eq("Animal.Speak")
    method.namespace.should eq("demo")
    method.parameters.try(&.map(&.name)).should eq(["prefix", "times"])
    method.parameters.try(&.map(&.type_name)).should eq(["string", "int"])
    method.return_type.should eq("string")
    method.declaration_id.should_not be_nil
    method.occurrence_id.should_not be_nil
    method.declaration_id.should eq(shifted_method.declaration_id)
    method.occurrence_id.should_not eq(shifted_method.occurrence_id)
    method.ast_node_type.should eq("method_declaration")
    method.extraction_method.should eq("tree_sitter_ast")
  end

  it "keeps Go variables, struct fields, and functions distinct in typed declarations" do
    source = <<-GO
      package demo

      var DefaultName string = "anonymous"
      type Person struct {
        Name string
        Age int
      }
      func NewPerson(name string) Person { return Person{Name: name} }
      GO
    result = Chiasmus::Graph::Extractor.extract_with_discovery(Chiasmus::Graph::SourceFile.new("person.go", source), "go") || raise "missing extraction"
    declarations = result.typed.declarations
    variable = declarations.find { |declaration| declaration.name == "DefaultName" } || raise "missing variable"
    name_field = declarations.find { |declaration| declaration.name == "Name" } || raise "missing Name field"
    age_field = declarations.find { |declaration| declaration.name == "Age" } || raise "missing Age field"
    constructor = declarations.find { |declaration| declaration.name == "NewPerson" } || raise "missing function"

    variable.kind.should eq("variable")
    variable.return_type.should eq("string")
    variable.mutable.should be_true
    [name_field, age_field].map(&.kind).should eq(["field", "field"])
    [name_field, age_field].map(&.owner).should eq(["Person", "Person"])
    [name_field, age_field].map(&.return_type).should eq(["string", "int"])
    constructor.kind.should eq("function")
    constructor.parameters.try(&.map(&.name)).should eq(["name"])
    constructor.return_type.should eq("Person")
    declarations.all? { |declaration| declaration.declaration_id.try(&.starts_with?("decl:v1:")) }.should be_true
  end

  it "preserves Go named types and multi-name value declarations" do
    source = <<-GO
      package demo
      type Count int
      type Label = string
      const First, Second = 1, 2
      var Left, Right int
      GO
    result = Chiasmus::Graph::Extractor.extract_with_discovery(Chiasmus::Graph::SourceFile.new("values.go", source), "go") || raise "missing extraction"
    declarations = result.typed.declarations
    expected_kinds = {"Count" => "defined_type", "Label" => "type_alias", "First" => "constant", "Second" => "constant", "Left" => "variable", "Right" => "variable"}
    expected_kinds.each do |name, kind|
      declaration = declarations.find { |item| item.name == name } || raise "missing #{name}"
      declaration.kind.should eq(kind)
      declaration.declaration_id.should_not be_nil
    end
    declarations.select { |item| item.name.in?("Left", "Right") }.map(&.return_type).should eq(["int", "int"])
  end

  it "extracts Crystal namespaces, types, constants, and structured methods" do
    source = <<-CR
      module Demo
        DEFAULT_LIMIT = 12

        class Widget
          private def render(width : Int32, label : String = "x") : Bool
            rendered = width > 0 && !label.empty?
            rendered
          end
        end
      end
      CR
    result = Chiasmus::Graph::Extractor.extract_with_discovery(
      Chiasmus::Graph::SourceFile.new("spec/chiasmus/unified_extraction_spec.cr", source), "crystal"
    ) || raise "missing extraction"
    declarations = result.typed.declarations

    namespace = declarations.find { |declaration| declaration.name == "Demo" } || raise "missing module"
    type = declarations.find { |declaration| declaration.name == "Widget" } || raise "missing class"
    constant = declarations.find { |declaration| declaration.name == "DEFAULT_LIMIT" } || raise "missing constant"
    method = declarations.find { |declaration| declaration.name == "render" } || raise "missing method"

    namespace.kind.should eq("module")
    namespace.qualified_name.should eq("Demo")
    namespace.extraction_method.should eq("tree_sitter_ast")
    type.kind.should eq("class")
    type.namespace.should eq("Demo")
    type.qualified_name.should eq("Demo.Widget")
    constant.kind.should eq("constant")
    constant.namespace.should eq("Demo")
    constant.qualified_name.should eq("Demo.DEFAULT_LIMIT")
    method.kind.should eq("method")
    method.namespace.should eq("Demo")
    method.owner.should eq("Demo.Widget")
    method.qualified_name.should eq("Demo.Widget.render")
    method.parameters.try(&.map { |parameter| {parameter.name, parameter.type_name, parameter.variadic?} }).should eq([
      {"width", "Int32", false}, {"label", "String", false},
    ])
    method.return_type.should eq("Bool")
    method.visibility.should eq("private")
    method.extraction_method.should eq("tree_sitter_ast")
    [namespace, type, constant, method].each do |declaration|
      declaration.declaration_id.should_not be_nil
      declaration.declaration_id.try(&.starts_with?("decl:v1:")).should be_true
      declaration.occurrence_id.should_not be_nil
      declaration.occurrence_id.try(&.starts_with?("occ:v1:")).should be_true
    end
  end

  it "keeps Crystal declaration IDs stable when source moves" do
    source = <<-CR
      module Demo
        class Widget
          def render(width : Int32) : Bool
            width > 0
          end
        end
      end
      CR
    first = Chiasmus::Graph::Extractor.extract_with_discovery(
      Chiasmus::Graph::SourceFile.new("spec/chiasmus/unified_extraction_spec.cr", source), "crystal"
    ) || raise "missing first extraction"
    shifted = Chiasmus::Graph::Extractor.extract_with_discovery(
      Chiasmus::Graph::SourceFile.new("spec/chiasmus/unified_extraction_spec.cr", "\n\n#{source}"), "crystal"
    ) || raise "missing shifted extraction"
    method = first.typed.declarations.find { |declaration| declaration.name == "render" } || raise "missing method"
    shifted_method = shifted.typed.declarations.find { |declaration| declaration.name == "render" } || raise "missing shifted method"

    method.declaration_id.should eq(shifted_method.declaration_id)
    method.occurrence_id.should_not eq(shifted_method.occurrence_id)
  end

  it "preserves Crystal structs, aliases, enum members, fields, and class methods" do
    source = <<-CR
      module Demo
        struct Entry
          @name : String
          @@count = 0

          def self.build(name : String) : Entry
            new
          end
        end

        enum Mode
          Fast
          Slow
        end

        alias Label = String
      end
      CR
    result = Chiasmus::Graph::Extractor.extract_with_discovery(
      Chiasmus::Graph::SourceFile.new("src/demo.cr", source), "crystal"
    ) || raise "missing extraction"
    declarations = result.typed.declarations
    entry = declarations.find { |item| item.name == "Entry" } || raise "missing struct"
    label = declarations.find { |item| item.name == "Label" } || raise "missing alias"
    fast = declarations.find { |item| item.name == "Fast" } || raise "missing enum member"
    slow = declarations.find { |item| item.name == "Slow" } || raise "missing enum member"
    name_field = declarations.find { |item| item.name == "@name" } || raise "missing field"
    count_field = declarations.find { |item| item.name == "@@count" } || raise "missing class field"
    build = declarations.find { |item| item.name == "build" } || raise "missing class method"

    entry.kind.should eq("struct")
    label.kind.should eq("type_alias")
    [fast, slow].map(&.kind).should eq(["enum_member", "enum_member"])
    [fast, slow].map(&.owner).should eq(["Demo.Mode", "Demo.Mode"])
    [name_field, count_field].map(&.kind).should eq(["field", "field"])
    [name_field, count_field].map(&.owner).should eq(["Demo.Entry", "Demo.Entry"])
    name_field.return_type.should eq("String")
    build.kind.should eq("method")
    build.static.should be_true
    build.owner.should eq("Demo.Entry")
    build.parameters.try(&.map(&.type_name)).should eq(["String"])
    declarations.all? { |item| item.declaration_id.try(&.starts_with?("decl:v1:")) }.should be_true
  end

  it "finds initializer-only Crystal fields without duplicating typed field declarations" do
    source = <<-CR
      class User
        @name : String

        def initialize(name : String, age : Int32)
          @name = name
          @age = age
        end
      end
      CR
    result = Chiasmus::Graph::Extractor.extract_with_discovery(
      Chiasmus::Graph::SourceFile.new("src/user.cr", source), "crystal"
    ) || raise "missing extraction"
    fields = result.typed.declarations.select { |item| item.kind == "field" }
    fields.map(&.name).should eq(["@name", "@age"])
    fields.map(&.owner).should eq(["User", "User"])
    fields.find { |item| item.name == "@name" }.try(&.return_type).should eq("String")
    fields.find { |item| item.name == "@age" }.try(&.return_type).should be_nil
  end

  it "retains macro-generated Crystal constants with explicit inferred provenance" do
    source = <<-CR
      module Package
        {% begin %}
          {% version = "1.0" %}
          VERSION = {{ version }}
        {% end %}
      end
      CR
    result = Chiasmus::Graph::Extractor.extract_with_discovery(
      Chiasmus::Graph::SourceFile.new("src/package.cr", source), "crystal"
    ) || raise "missing extraction"
    version = result.typed.declarations.find { |item| item.name == "VERSION" } || raise "missing generated constant"
    version.kind.should eq("constant")
    version.namespace.should eq("Package")
    version.extraction_method.should eq("macro_inference")
    version.declaration_id.should_not be_nil
    version.occurrence_id.should_not be_nil
  end

  it "reuses a combined extraction and invalidates it on content edits" do
    dir = File.join(Dir.tempdir, "chiasmus-unified-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      path = File.join(dir, "Greeter.java")
      cache_dir = File.join(dir, "cache")
      parser = CountingJavaParser.new
      first_source = "class Greeter { void greet() {} }"
      second_source = "class Greeter { void greet() {} void wave() {} }"

      first = Chiasmus::Graph::Extractor.extract_with_discovery(
        Chiasmus::Graph::SourceFile.new(path, first_source), "java", parser,
        cache_dir: cache_dir, repo_key: "unified-spec"
      )
      Chiasmus::Graph::GraphCache.close_file_cache_stores_for_test
      warm = Chiasmus::Graph::Extractor.extract_with_discovery(
        Chiasmus::Graph::SourceFile.new(path, first_source), "java", parser,
        cache_dir: cache_dir, repo_key: "unified-spec"
      )
      edited = Chiasmus::Graph::Extractor.extract_with_discovery(
        Chiasmus::Graph::SourceFile.new(path, second_source), "java", parser,
        cache_dir: cache_dir, repo_key: "unified-spec"
      )

      parser.parse_count.should eq(2)
      warm.should eq(first)
      warm.try(&.typed).should eq(first.try(&.typed))
      edited_result = edited || raise "expected edited extraction"
      edited_result.discovery.items.map(&.name).should contain("wave")
      edited_result.graph.defines.map(&.name).should contain("wave")
    ensure
      Chiasmus::Graph::GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(dir)
    end
  end

  it "reuses typed declarations across checkout roots without retaining the old path" do
    dir = File.join(Dir.tempdir, "chiasmus-typed-worktrees-#{Random::Secure.hex(8)}")
    cache_dir = File.join(dir, "cache")
    first_root = File.join(dir, "first")
    second_root = File.join(dir, "second")
    [first_root, second_root].each do |root|
      Dir.mkdir_p(File.join(root, ".git"))
      Dir.mkdir_p(File.join(root, "src"))
      File.write(File.join(root, ".git", "HEAD"), "ref: refs/heads/main\n")
    end

    begin
      content = "class Greeter { void greet(String name) {} }"
      first_path = File.join(first_root, "src", "Greeter.java")
      second_path = File.join(second_root, "src", "Greeter.java")
      File.write(first_path, content)
      File.write(second_path, content)
      Chiasmus::Graph::GraphCache.logical_source_path(first_path).should eq("src/Greeter.java")
      Chiasmus::Graph::GraphCache.logical_source_path(second_path).should eq("src/Greeter.java")
      parser = CountingJavaParser.new
      first = Chiasmus::Graph::Extractor.extract_with_discovery(
        Chiasmus::Graph::SourceFile.new(first_path, content), "java", parser,
        cache_dir: cache_dir, repo_key: "shared-worktree-spec"
      ) || raise "missing first extraction"
      second = Chiasmus::Graph::Extractor.extract_with_discovery(
        Chiasmus::Graph::SourceFile.new(second_path, content), "java", parser,
        cache_dir: cache_dir, repo_key: "shared-worktree-spec"
      ) || raise "missing second extraction"

      parser.parse_count.should eq(1)
      first.typed.declarations.map(&.declaration_id).should eq(second.typed.declarations.map(&.declaration_id))
      first.typed.declarations.map(&.occurrence_id).should eq(second.typed.declarations.map(&.occurrence_id))
      second.typed.declarations.map(&.file).uniq.should eq([second_path])
      second.graph.defines.map(&.file).uniq.should eq([second_path])
    ensure
      Chiasmus::Graph::GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(dir)
    end
  end

  it "coalesces concurrent requests for one cached file" do
    dir = File.join(Dir.tempdir, "chiasmus-unified-concurrent-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      file = Chiasmus::Graph::SourceFile.new(File.join(dir, "Greeter.java"), "class Greeter { void greet() {} }")
      parser = CountingJavaParser.new
      results = Channel(Chiasmus::Graph::Extractor::UnifiedFileResult?).new(2)
      2.times do
        spawn do
          results.send(Chiasmus::Graph::Extractor.extract_with_discovery(file, "java", parser, cache_dir: File.join(dir, "cache"), repo_key: "single-flight"))
        end
      end
      first = results.receive
      second = results.receive
      first.should eq(second)
      parser.parse_count.should eq(1)
    ensure
      Chiasmus::Graph::GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(dir)
    end
  end

  it "extracts typed Rust items, members, and callable signatures beside legacy facts" do
    source = <<-RUST
      pub mod demo {
        pub const LIMIT: usize = 8;
        pub struct Worker { pub name: String, retries: u32 }
        pub enum State { Ready, Busy(u32) }
        pub trait Service {
          fn run(&self, input: &str) -> Result<(), Error>;
        }
        impl Worker {
          pub fn build(name: String) -> Self { todo!() }
          fn retry(&mut self, count: u32) -> bool { true }
        }
        pub fn start(worker: &Worker, limit: usize) -> Result<(), Error> { todo!() }
      }
      RUST
    result = Chiasmus::Graph::Extractor.extract_with_discovery(
      Chiasmus::Graph::SourceFile.new("src/lib.rs", source), "rust"
    ) || raise "missing extraction"
    declarations = result.typed.declarations

    worker = declarations.find { |item| item.name == "Worker" } || raise "missing struct"
    state = declarations.find { |item| item.name == "State" } || raise "missing enum"
    trait = declarations.find { |item| item.name == "Service" } || raise "missing trait"
    limit = declarations.find { |item| item.name == "LIMIT" } || raise "missing constant"
    name_field = declarations.find { |item| item.name == "name" && item.kind == "field" } || raise "missing field"
    ready = declarations.find { |item| item.name == "Ready" } || raise "missing enum variant"
    run = declarations.find { |item| item.name == "run" } || raise "missing trait method"
    build = declarations.find { |item| item.name == "build" } || raise "missing impl method"
    start = declarations.find { |item| item.name == "start" } || raise "missing function"

    worker.kind.should eq("struct")
    state.kind.should eq("enum")
    trait.kind.should eq("trait")
    [worker, state, trait, limit].each { |item| item.namespace.should eq("demo") }
    limit.kind.should eq("constant")
    limit.return_type.should eq("usize")
    name_field.owner.should eq("demo.Worker")
    name_field.return_type.should eq("String")
    ready.kind.should eq("enum_variant")
    ready.owner.should eq("demo.State")
    run.kind.should eq("method")
    run.owner.should eq("demo.Service")
    run.parameters.try(&.map { |parameter| {parameter.name, parameter.type_name} }).should eq([
      {"self", "&self"}, {"input", "&str"},
    ])
    run.return_type.should eq("Result<(), Error>")
    build.kind.should eq("method")
    build.owner.should eq("demo.Worker")
    build.parameters.try(&.map { |parameter| {parameter.name, parameter.type_name} }).should eq([{"name", "String"}])
    build.return_type.should eq("Self")
    start.kind.should eq("function")
    start.namespace.should eq("demo")
    start.parameters.try(&.map { |parameter| {parameter.name, parameter.type_name} }).should eq([
      {"worker", "&Worker"}, {"limit", "usize"},
    ])
    start.return_type.should eq("Result<(), Error>")
    result.graph.defines.map(&.name).should contain("build")
    result.discovery.items.map(&.name).should contain("Worker")
  end

  it "assigns Rust local IDs, legacy aliases, and movement-sensitive occurrences" do
    source = <<-RUST
      mod demo {
        struct Worker;
        impl Worker {
          fn run(input: u32) -> bool { true }
        }
      }
      RUST
    first = Chiasmus::Graph::Extractor.extract_with_discovery(
      Chiasmus::Graph::SourceFile.new("src/lib.rs", source), "rust"
    ) || raise "missing first extraction"
    shifted = Chiasmus::Graph::Extractor.extract_with_discovery(
      Chiasmus::Graph::SourceFile.new("src/lib.rs", "\n\n#{source}"), "rust"
    ) || raise "missing shifted extraction"
    method = first.typed.declarations.find { |item| item.name == "run" } || raise "missing method"
    shifted_method = shifted.typed.declarations.find { |item| item.name == "run" } || raise "missing shifted method"

    method.declaration_id.try(&.starts_with?("decl:v1:")).should be_true
    method.occurrence_id.try(&.starts_with?("occ:v1:")).should be_true
    method.declaration_id.should eq(shifted_method.declaration_id)
    method.occurrence_id.should_not eq(shifted_method.occurrence_id)
    method.legacy_aliases.should eq(["src/lib.rs::method::demo.Worker.run"])
  end

  it "relocates cached Rust typed declarations between checkout roots" do
    dir = File.join(Dir.tempdir, "chiasmus-rust-typed-worktrees-#{Random::Secure.hex(8)}")
    cache_dir = File.join(dir, "cache")
    first_root = File.join(dir, "first")
    second_root = File.join(dir, "second")
    [first_root, second_root].each do |root|
      Dir.mkdir_p(File.join(root, ".git"))
      Dir.mkdir_p(File.join(root, "src"))
      File.write(File.join(root, ".git", "HEAD"), "ref: refs/heads/main\n")
    end

    begin
      content = "pub mod demo { pub struct Worker; impl Worker { pub fn run(value: u32) -> bool { true } } }\n"
      first_path = File.join(first_root, "src", "lib.rs")
      second_path = File.join(second_root, "src", "lib.rs")
      File.write(first_path, content)
      File.write(second_path, content)
      first = Chiasmus::Graph::Extractor.extract_with_discovery(
        Chiasmus::Graph::SourceFile.new(first_path, content), "rust",
        cache_dir: cache_dir, repo_key: "rust-shared-worktree-spec"
      ) || raise "missing first extraction"
      second = Chiasmus::Graph::Extractor.extract_with_discovery(
        Chiasmus::Graph::SourceFile.new(second_path, content), "rust",
        cache_dir: cache_dir, repo_key: "rust-shared-worktree-spec"
      ) || raise "missing relocated extraction"

      first.typed.declarations.map(&.declaration_id).should eq(second.typed.declarations.map(&.declaration_id))
      first.typed.declarations.map(&.occurrence_id).should eq(second.typed.declarations.map(&.occurrence_id))
      second.typed.declarations.map(&.file).uniq.should eq([second_path])
      second.typed.declarations.all? { |item| item.legacy_aliases.all? { |alias_id| alias_id.starts_with?(second_path) } }.should be_true
    ensure
      Chiasmus::Graph::GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(dir)
    end
  end
end
