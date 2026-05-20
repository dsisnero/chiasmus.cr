require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/type_env"

include Chiasmus::Graph

private def typescript_language : TreeSitter::Language
  vendor_dir = File.expand_path("../../../vendor/grammars", __DIR__)
  ext = {% if flag?(:darwin) %} "dylib" {% else %} "so" {% end %}
  lib_path = File.join(vendor_dir, "tree-sitter-typescript", "libtree-sitter-typescript.#{ext}")
  raise "TypeScript grammar not found at #{lib_path}" unless File.exists?(lib_path)

  handle = LibC.dlopen(lib_path.to_s, LibC::RTLD_LAZY | LibC::RTLD_LOCAL)
  ptr = LibC.dlsym(handle, "tree_sitter_typescript")
  lang_ptr = Proc(LibTreeSitter::TSLanguage*).new(ptr, Pointer(Void).null).call
  TreeSitter::Language.new("typescript", lang_ptr)
end

private def parse_ts(source : String) : TreeSitter::Node
  lang = typescript_language
  parser = TreeSitter::Parser.new(language: lang)
  tree = parser.parse(nil, source)
  tree.root_node
end

describe TypeEnv, "integration" do
  describe ".collect_type_info" do
    it "extracts class fields from public_field_definition" do
      src = "class App { svc: Svc; }"
      root = parse_ts(src)
      info = TypeEnv.collect_type_info(root, src, "test.ts")
      info.class_fields.size.should eq 1
      info.class_fields[0].class_name.should eq "App"
      info.class_fields[0].fields["svc"].should eq "Svc"
    end

    it "extracts class extends relationships" do
      src = "class Svc {} class App extends Svc {}"
      root = parse_ts(src)
      info = TypeEnv.collect_type_info(root, src, "test.ts")
      extends = info.class_extends.not_nil!
      extends.size.should eq 1
      extends[0].class_name.should eq "App"
      extends[0].parent.should eq "Svc"
    end

    it "extracts method names from classes" do
      src = "class Foo { login() {} logout() {} }"
      root = parse_ts(src)
      info = TypeEnv.collect_type_info(root, src, "test.ts")
      methods = info.class_methods.not_nil!
      methods.size.should eq 1
      methods[0].class_name.should eq "Foo"
      methods[0].methods.should contain "login"
      methods[0].methods.should contain "logout"
    end

    it "returns nil class_methods when no methods found" do
      src = "class Empty {}"
      root = parse_ts(src)
      info = TypeEnv.collect_type_info(root, src, "test.ts")
      info.class_methods.should be_nil
    end

    it "handles constructor parameter properties" do
      src = "class App { constructor(private readonly auth: Auth) {} }"
      root = parse_ts(src)
      info = TypeEnv.collect_type_info(root, src, "test.ts")
      info.class_fields[0].fields["auth"]?.should eq "Auth"
    end

    it "extracts interface property signatures" do
      src = "interface User { name: string; age: number; }"
      root = parse_ts(src)
      info = TypeEnv.collect_type_info(root, src, "test.ts")
      info.class_fields[0].fields.has_key?("name").should be_true
      info.class_fields[0].fields.has_key?("age").should be_true
    end

    it "collects info from multiple classes in one file" do
      src = "class A { x: number; } class B { y: string; }"
      root = parse_ts(src)
      info = TypeEnv.collect_type_info(root, src, "test.ts")
      info.class_fields.size.should eq 2
    end
  end
end
