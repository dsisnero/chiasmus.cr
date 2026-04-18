require "spec"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/extractor"

describe "Crystal walker" do
  it "extracts class and module definitions" do
    crystal_code = <<-CRYSTAL
    module MyModule
      def self.module_method
        puts "module method"
      end
    end

    class MyClass
      def instance_method
        puts "instance method"
      end

      def self.class_method
        puts "class method"
      end
    end

    def top_level_function
      puts "top level"
    end
    CRYSTAL

    file = Chiasmus::Graph::SourceFile.new("test.cr", crystal_code)
    facts = Chiasmus::Graph::Extractor.extract_graph([file])

    # Check defines
    defines = facts.defines.sort_by(&.name)
    defines.size.should eq(6)

    # Check module
    mymodule = defines.find { |d| d.name == "MyModule" }
    mymodule.should_not be_nil
    mymodule.not_nil!.kind.should eq(Chiasmus::Graph::SymbolKind::Interface)
    mymodule.not_nil!.line.should eq(1)

    # Check class
    myclass = defines.find { |d| d.name == "MyClass" }
    myclass.should_not be_nil
    myclass.not_nil!.kind.should eq(Chiasmus::Graph::SymbolKind::Class)
    myclass.not_nil!.line.should eq(7)

    # Check methods
    module_method = defines.find { |d| d.name == "module_method" }
    module_method.should_not be_nil
    module_method.not_nil!.kind.should eq(Chiasmus::Graph::SymbolKind::Method)
    module_method.not_nil!.line.should eq(2)

    instance_method = defines.find { |d| d.name == "instance_method" }
    instance_method.should_not be_nil
    instance_method.not_nil!.kind.should eq(Chiasmus::Graph::SymbolKind::Function)
    instance_method.not_nil!.line.should eq(8)

    class_method = defines.find { |d| d.name == "class_method" }
    class_method.should_not be_nil
    class_method.not_nil!.kind.should eq(Chiasmus::Graph::SymbolKind::Method)
    class_method.not_nil!.line.should eq(12)

    top_level_function = defines.find { |d| d.name == "top_level_function" }
    top_level_function.should_not be_nil
    top_level_function.not_nil!.kind.should eq(Chiasmus::Graph::SymbolKind::Function)
    top_level_function.not_nil!.line.should eq(17)

    # Check contains relationships
    contains = facts.contains
    contains.size.should eq(3)

    # Check MyClass contains both methods
    myclass_contains = contains.select { |c| c.parent == "MyClass" }.map(&.child).sort!
    myclass_contains.should eq(["class_method", "instance_method"])

    # Check MyModule contains module_method
    mymodule_contains = contains.select { |c| c.parent == "MyModule" }.map(&.child)
    mymodule_contains.should eq(["module_method"])

    # Check calls
    calls = facts.calls.sort_by(&.caller)
    calls.size.should eq(4)

    calls[0].caller.should eq("class_method")
    calls[0].callee.should eq("puts")

    calls[1].caller.should eq("instance_method")
    calls[1].callee.should eq("puts")

    calls[2].caller.should eq("module_method")
    calls[2].callee.should eq("puts")

    calls[3].caller.should eq("top_level_function")
    calls[3].callee.should eq("puts")
  end

  it "extracts require and require_relative imports" do
    crystal_code = <<-CRYSTAL
    require "json"
    require_relative "./my_module"
    require "./other"
    require "crystal_lib"

    module MyModule
      def self.some_method
        puts "hello"
      end
    end
    CRYSTAL

    file = Chiasmus::Graph::SourceFile.new("test.cr", crystal_code)
    facts = Chiasmus::Graph::Extractor.extract_graph([file])

    # Check imports
    imports = facts.imports.sort_by(&.name)
    imports.size.should eq(4)

    imports[0].name.should eq("./my_module")
    imports[0].source.should eq("./my_module")

    imports[1].name.should eq("crystal_lib")
    imports[1].source.should eq("crystal_lib")

    imports[2].name.should eq("json")
    imports[2].source.should eq("json")

    imports[3].name.should eq("other")
    imports[3].source.should eq("./other")
  end

  it "handles nested classes and modules" do
    crystal_code = <<-CRYSTAL
    module OuterModule
      class InnerClass
        def inner_method
          puts "inner"
        end
      end

      def self.outer_method
        puts "outer"
      end
    end
    CRYSTAL

    file = Chiasmus::Graph::SourceFile.new("test.cr", crystal_code)
    facts = Chiasmus::Graph::Extractor.extract_graph([file])

    # Check defines
    defines = facts.defines.sort_by(&.name)
    defines.size.should eq(4)

    defines[0].name.should eq("InnerClass")
    defines[0].kind.should eq(Chiasmus::Graph::SymbolKind::Class)

    defines[1].name.should eq("OuterModule")
    defines[1].kind.should eq(Chiasmus::Graph::SymbolKind::Interface)

    defines[2].name.should eq("inner_method")
    defines[2].kind.should eq(Chiasmus::Graph::SymbolKind::Function)

    defines[3].name.should eq("outer_method")
    defines[3].kind.should eq(Chiasmus::Graph::SymbolKind::Method)

    # Check contains relationships
    contains = facts.contains.sort_by(&.parent)
    contains.size.should eq(2) # Only methods are contained, not nested classes

    contains[0].parent.should eq("InnerClass")
    contains[0].child.should eq("inner_method")

    contains[1].parent.should eq("OuterModule")
    contains[1].child.should eq("outer_method")
  end

  it "handles method calls with arguments" do
    crystal_code = <<-CRYSTAL
    class Calculator
      def add(a, b)
        result = a + b
        print_result(result)
      end

      def self.print_result(value)
        puts "Result: " + value.to_s
      end
    end
    CRYSTAL

    file = Chiasmus::Graph::SourceFile.new("test.cr", crystal_code)
    facts = Chiasmus::Graph::Extractor.extract_graph([file])

    # Check calls - we get operators like + and to_s as well
    calls = facts.calls.sort_by(&.caller)
    calls.size.should be >= 3 # At least 3 calls, but may include operators

    # add should call print_result
    add_calls = calls.select { |c| c.caller == "add" }
    add_calls.should_not be_empty

    # Should include print_result call from add
    print_result_call_from_add = add_calls.find { |c| c.callee == "print_result" }
    print_result_call_from_add.should_not be_nil

    # print_result should call puts
    print_result_calls = calls.select { |c| c.caller == "print_result" }
    print_result_calls.should_not be_empty

    puts_call_from_print_result = print_result_calls.find { |c| c.callee == "puts" }
    puts_call_from_print_result.should_not be_nil
  end
end
