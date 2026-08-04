require "../../spec_helper"
require "../../../src/chiasmus/graph/graph_codec"

include Chiasmus::Graph

describe GraphCodec do
  it "round-trips every persisted CodeGraph field" do
    graph = CodeGraph.new(
      defines: [DefinesFact.new(
        file: "/repo/src/demo.cr",
        name: "run",
        kind: SymbolKind::Method,
        span: Chiasmus::Graph::Span.line_range(3, 7),
        signature: "def run(value : String) : Nil",
        qualified_name: "Demo.run"
      )],
      calls: [CallsFact.new(caller: "run", callee: "helper", caller_qn: "Demo.run", callee_qn: "Demo.helper")],
      imports: [ImportsFact.new(file: "/repo/src/demo.cr", name: "JSON", source: "json")],
      exports: [ExportsFact.new(file: "/repo/src/demo.cr", name: "run")],
      contains: [ContainsFact.new(parent: "Demo", child: "run")],
      files: [FileNode.new(path: "/repo/src/demo.cr", language: "crystal", line_count: 9, token_estimate: 24, file_doc: "Demo docs")],
      type_info: [FileTypeInfo.new(
        file: "/repo/src/demo.cr",
        class_fields: [ClassFieldEntry.new(class_name: "Demo", fields: {"@name" => "String"})],
        class_methods: [ClassMethodEntry.new(class_name: "Demo", methods: ["run"])],
        class_extends: [ClassExtendsEntry.new(class_name: "Demo", parent: "Base")],
        pending_calls: [PendingCall.new(
          caller: "run",
          callee: "helper",
          receiver_chain: ["self"],
          enclosing_class: "Demo",
          var_types: {"value" => "String"}
        )]
      )]
    )

    GraphCodec.decode(GraphCodec.encode(graph)).should eq(graph)
  end

end
