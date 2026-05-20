require "../../spec_helper"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/resolve_calls"

include Chiasmus::Graph

describe CallResolver do
  describe ".build_class_field_registry" do
    it "builds registry from per-file class fields" do
      info = FileTypeInfo.new(
        file: "test.ts",
        class_fields: [
          ClassFieldEntry.new(
            class_name: "App",
            fields: {"svc" => "Svc"},
          ),
          ClassFieldEntry.new(
            class_name: "Svc",
            fields: Hash(String, String).new,
          ),
        ],
      )
      registry = CallResolver.build_class_field_registry([info])
      registry.has_key?("App").should be_true
      registry.has_key?("Svc").should be_true
      registry["App"]["svc"].should eq "Svc"
    end

    it "propagates parent fields to children" do
      info = FileTypeInfo.new(
        file: "test.ts",
        class_fields: [
          ClassFieldEntry.new(
            class_name: "Parent",
            fields: {"x" => "number"},
          ),
          ClassFieldEntry.new(
            class_name: "Child",
            fields: {"y" => "string"},
          ),
        ],
        class_extends: [
          ClassExtendsEntry.new(class_name: "Child", parent: "Parent"),
        ],
      )
      registry = CallResolver.build_class_field_registry([info])
      registry["Child"]["x"].should eq "number"
      registry["Child"]["y"].should eq "string"
    end

    it "child fields shadow parent fields" do
      info = FileTypeInfo.new(
        file: "test.ts",
        class_fields: [
          ClassFieldEntry.new(
            class_name: "Parent",
            fields: {"x" => "number"},
          ),
          ClassFieldEntry.new(
            class_name: "Child",
            fields: {"x" => "string"},
          ),
        ],
        class_extends: [
          ClassExtendsEntry.new(class_name: "Child", parent: "Parent"),
        ],
      )
      registry = CallResolver.build_class_field_registry([info])
      registry["Child"]["x"].should eq "string"
    end

    it "handles inheritance cycles safely" do
      info = FileTypeInfo.new(
        file: "test.ts",
        class_fields: [
          ClassFieldEntry.new(
            class_name: "A",
            fields: {"a" => "number"},
          ),
          ClassFieldEntry.new(
            class_name: "B",
            fields: {"b" => "string"},
          ),
        ],
        class_extends: [
          ClassExtendsEntry.new(class_name: "A", parent: "B"),
          ClassExtendsEntry.new(class_name: "B", parent: "A"),
        ],
      )
      registry = CallResolver.build_class_field_registry([info])
      registry["A"].has_key?("a").should be_true
      registry["B"].has_key?("b").should be_true
    end
  end

  describe ".build_class_method_registry" do
    it "builds method registry with flat/own/parents" do
      info = FileTypeInfo.new(
        file: "test.ts",
        class_methods: [
          ClassMethodEntry.new(
            class_name: "Parent",
            methods: ["run"],
          ),
          ClassMethodEntry.new(
            class_name: "Child",
            methods: ["start"],
          ),
        ],
        class_extends: [
          ClassExtendsEntry.new(class_name: "Child", parent: "Parent"),
        ],
      )
      mr = CallResolver.build_class_method_registry([info])
      mr.own["Parent"]?.try(&.includes?("run")).should be_true
      mr.own["Child"]?.try(&.includes?("start")).should be_true
      mr.parents["Child"]?.should eq "Parent"
      mr.flat["Child"]?.try(&.includes?("run")).should be_true
      mr.flat["Child"]?.try(&.includes?("start")).should be_true
    end
  end

  describe ".resolve_calls_with_registry" do
    it "resolves this.method() to Class.method QN" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "test.ts", name: "Foo", kind: SymbolKind::Class, line: 1),
          DefinesFact.new(file: "test.ts", name: "run", kind: SymbolKind::Method, line: 2),
          DefinesFact.new(file: "test.ts", name: "worker", kind: SymbolKind::Method, line: 3),
        ],
        calls: [
          CallsFact.new(caller: "run", callee: "worker"),
        ],
        contains: [
          ContainsFact.new(parent: "Foo", child: "run"),
          ContainsFact.new(parent: "Foo", child: "worker"),
        ],
        type_info: [
          FileTypeInfo.new(
            file: "test.ts",
            class_fields: [
              ClassFieldEntry.new(class_name: "Foo", fields: Hash(String, String).new),
            ],
            class_methods: [
              ClassMethodEntry.new(class_name: "Foo", methods: ["run", "worker"]),
            ],
            pending_calls: [
              PendingCall.new(
                caller: "run",
                callee: "worker",
                receiver_chain: ["this"],
                enclosing_class: "Foo",
              ),
            ],
          ),
        ],
      )
      registry = CallResolver.build_class_field_registry(graph.type_info.not_nil!)
      results = CallResolver.resolve_calls_with_registry(graph, registry)

      results["run\0worker"].should eq "Foo.worker"
    end

    it "resolves localVar.method() with explicit annotation" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "test.ts", name: "Svc", kind: SymbolKind::Class, line: 1),
          DefinesFact.new(file: "test.ts", name: "f", kind: SymbolKind::Function, line: 4),
          DefinesFact.new(file: "test.ts", name: "login", kind: SymbolKind::Method, line: 2),
        ],
        calls: [
          CallsFact.new(caller: "f", callee: "login"),
        ],
        contains: [
          ContainsFact.new(parent: "Svc", child: "login"),
        ],
        type_info: [
          FileTypeInfo.new(
            file: "test.ts",
            class_fields: [
              ClassFieldEntry.new(class_name: "Svc", fields: Hash(String, String).new),
            ],
            class_methods: [
              ClassMethodEntry.new(class_name: "Svc", methods: ["login"]),
            ],
            pending_calls: [
              PendingCall.new(
                caller: "f",
                callee: "login",
                receiver_chain: ["s"],
                var_types: {"s" => "Svc"},
              ),
            ],
          ),
        ],
      )
      registry = CallResolver.build_class_field_registry(graph.type_info.not_nil!)
      results = CallResolver.resolve_calls_with_registry(graph, registry)

      results["f\0login"].should eq "Svc.login"
    end

    it "rejects JS builtin types" do
      graph = CodeGraph.new(
        defines: [] of DefinesFact,
        calls: [
          CallsFact.new(caller: "f", callee: "has"),
        ],
        type_info: [
          FileTypeInfo.new(
            file: "test.ts",
            class_fields: [] of ClassFieldEntry,
            pending_calls: [
              PendingCall.new(
                caller: "f",
                callee: "has",
                receiver_chain: ["m"],
                var_types: {"m" => "Map"},
              ),
            ],
          ),
        ],
      )
      registry = CallResolver.build_class_field_registry(graph.type_info.not_nil!)
      results = CallResolver.resolve_calls_with_registry(graph, registry)

      results.has_key?("f\0has").should be_false
    end

    it "falls back to unique method owner when chain fails" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "test.ts", name: "Helper", kind: SymbolKind::Class, line: 1),
          DefinesFact.new(file: "test.ts", name: "foo", kind: SymbolKind::Method, line: 2),
        ],
        calls: [
          CallsFact.new(caller: "main", callee: "foo"),
        ],
        contains: [
          ContainsFact.new(parent: "Helper", child: "foo"),
        ],
        type_info: [
          FileTypeInfo.new(
            file: "test.ts",
            class_fields: [] of ClassFieldEntry,
            class_methods: [
              ClassMethodEntry.new(class_name: "Helper", methods: ["foo"]),
            ],
            pending_calls: [
              PendingCall.new(
                caller: "main",
                callee: "foo",
                receiver_chain: ["unknown"],
              ),
            ],
          ),
        ],
      )
      registry = CallResolver.build_class_field_registry(graph.type_info.not_nil!)
      results = CallResolver.resolve_calls_with_registry(graph, registry)

      results["main\0foo"].should eq "Helper.foo"
    end

    it "leaves call unresolved when receiver is ambiguous" do
      graph = CodeGraph.new(
        defines: [
          DefinesFact.new(file: "test.ts", name: "A", kind: SymbolKind::Class, line: 1),
          DefinesFact.new(file: "test.ts", name: "B", kind: SymbolKind::Class, line: 2),
          DefinesFact.new(file: "test.ts", name: "run", kind: SymbolKind::Method, line: 3),
          DefinesFact.new(file: "test.ts", name: "f", kind: SymbolKind::Function, line: 4),
        ],
        calls: [
          CallsFact.new(caller: "f", callee: "run"),
        ],
        contains: [
          ContainsFact.new(parent: "A", child: "run"),
          ContainsFact.new(parent: "B", child: "run"),
        ],
        type_info: [
          FileTypeInfo.new(
            file: "test.ts",
            class_fields: [] of ClassFieldEntry,
            class_methods: [
              ClassMethodEntry.new(class_name: "A", methods: ["run"]),
              ClassMethodEntry.new(class_name: "B", methods: ["run"]),
            ],
            pending_calls: [
              PendingCall.new(
                caller: "f",
                callee: "run",
                receiver_chain: ["unknown"],
              ),
            ],
          ),
        ],
      )
      registry = CallResolver.build_class_field_registry(graph.type_info.not_nil!)
      results = CallResolver.resolve_calls_with_registry(graph, registry)

      results.has_key?("f\0run").should be_false
    end
  end
end
