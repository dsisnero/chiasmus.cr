require "../../spec_helper"
require "../../../src/chiasmus/graph/port_dom"

module PortDomSpecSupport
  def self.defines(name : String, kind : Chiasmus::Graph::SymbolKind, file : String = "src/sample.cr") : Chiasmus::Graph::DefinesFact
    Chiasmus::Graph::DefinesFact.new(
      file: file,
      name: name,
      kind: kind,
      span: Chiasmus::Graph::Span.line_range(1, 1),
      qualified_name: name,
    )
  end

  def self.graph : Chiasmus::Graph::CodeGraph
    Chiasmus::Graph::CodeGraph.new(defines: [
      defines("Widget", Chiasmus::Graph::SymbolKind::Class),
      defines("render", Chiasmus::Graph::SymbolKind::Method),
      defines("Rebuild", Chiasmus::Graph::SymbolKind::Module),
      defines("counter", Chiasmus::Graph::SymbolKind::Variable),
      defines("handle", Chiasmus::Graph::SymbolKind::Function),
    ])
  end
end

describe Chiasmus::Graph::PortDom do
  it "classifies symbols into typed surfaces" do
    dom = Chiasmus::Graph::PortDom.build(PortDomSpecSupport.graph)

    dom.types.map(&.kind).should contain(Chiasmus::Graph::PortDom::SurfaceKind::Class)
    dom.types.map(&.kind).should contain(Chiasmus::Graph::PortDom::SurfaceKind::Module)
    dom.methods.map(&.name).should contain("render")
    dom.methods.map(&.name).should contain("handle")
    dom.properties.map(&.name).should contain("counter")
  end

  it "maps symbol kinds to surface kinds" do
    Chiasmus::Graph::PortDom.surface_kind(Chiasmus::Graph::SymbolKind::Class).should eq(Chiasmus::Graph::PortDom::SurfaceKind::Class)
    Chiasmus::Graph::PortDom.surface_kind(Chiasmus::Graph::SymbolKind::Interface).should eq(Chiasmus::Graph::PortDom::SurfaceKind::Interface)
    Chiasmus::Graph::PortDom.surface_kind(Chiasmus::Graph::SymbolKind::Module).should eq(Chiasmus::Graph::PortDom::SurfaceKind::Module)
    Chiasmus::Graph::PortDom.surface_kind(Chiasmus::Graph::SymbolKind::Type).should eq(Chiasmus::Graph::PortDom::SurfaceKind::Alias)
  end

  it "round-trips symbols through CodeGraph -> PortDom -> CodeGraph" do
    original = PortDomSpecSupport.graph
    dom = Chiasmus::Graph::PortDom.build(original)
    restored = dom.to_code_graph

    original_names = original.defines.map { |fact| {fact.name, fact.kind} }.sort_by { |name, kind| "#{name}:#{kind}" }
    restored_names = restored.defines.map { |fact| {fact.name, fact.kind} }.sort_by { |name, kind| "#{name}:#{kind}" }
    restored_names.should eq(original_names)
    dom.symbols.size.should eq(original.defines.size)
  end

  it "parses parameters and a return type from a signature" do
    params, return_type = Chiasmus::Graph::PortDom.parse_signature("(a: Int32, b: String) -> Bool")
    params.map(&.name).should eq(["a", "b"])
    params.map(&.type.not_nil!.name).should eq(["Int32", "String"])
    return_type.not_nil!.name.should eq("Bool")
  end

  it "parses a signature without a return type" do
    params, return_type = Chiasmus::Graph::PortDom.parse_signature("(self, x: T)")
    params.map(&.name).should eq(["self", "x"])
    return_type.should be_nil
  end

  it "handles nil and empty signatures" do
    params, return_type = Chiasmus::Graph::PortDom.parse_signature(nil)
    params.should be_empty
    return_type.should be_nil

    params, return_type = Chiasmus::Graph::PortDom.parse_signature("()")
    params.should be_empty
    return_type.should be_nil
  end

  it "populates method surfaces from graph signatures" do
    graph = Chiasmus::Graph::CodeGraph.new(defines: [
      Chiasmus::Graph::DefinesFact.new(
        file: "src/lib.rs",
        name: "compute",
        kind: Chiasmus::Graph::SymbolKind::Function,
        span: Chiasmus::Graph::Span.line_range(1, 1),
        qualified_name: "compute",
        signature: "(n: u64) -> u64",
      ),
    ])

    method = Chiasmus::Graph::PortDom.build(graph).methods.first
    method.params.size.should eq(1)
    method.params.first.name.should eq("n")
    method.params.first.type.not_nil!.name.should eq("u64")
    method.return_type.not_nil!.name.should eq("u64")
  end
end
