require "../../spec_helper"
require "../../../src/chiasmus/parity/surface"

module SurfaceSpecSupport
  def self.method(file : String, qualified : String, signature : String) : Chiasmus::Graph::DefinesFact
    Chiasmus::Graph::DefinesFact.new(
      file: file,
      name: qualified.split('.').last,
      kind: Chiasmus::Graph::SymbolKind::Method,
      span: Chiasmus::Graph::Span.line_range(1, 1),
      signature: signature,
      qualified_name: qualified,
    )
  end
end

describe Chiasmus::Parity::Surface do
  rules = Chiasmus::Parity::Rules::RuleSet.new
  typed_rules = Chiasmus::Parity::Rules::RuleSet.from_yaml(<<-YAML)
  version: 1
  source:
    type_map:
      int: int
      void: nil
  target:
    type_map:
      Int32: int
      Nil: nil
  YAML

  it "flags arity drift between mapped methods" do
    source = Chiasmus::Graph::CodeGraph.new(defines: [
      SurfaceSpecSupport.method("a.java", "Calc.add", "(int a, int b) -> int"),
    ])
    target = Chiasmus::Graph::CodeGraph.new(defines: [
      SurfaceSpecSupport.method("b.cr", "Calc.add", "(a) -> Int32"),
    ])

    mappings = Chiasmus::Parity::Reconcile.mappings(source, target, rules)
    report = Chiasmus::Parity::Surface.compare(source, target, mappings).first
    report.status.should eq("surface_mismatch")
    report.source_arity.should eq(2)
    report.target_arity.should eq(1)
  end

  it "matches when arity agrees and types normalize equal across languages" do
    source = Chiasmus::Graph::CodeGraph.new(defines: [
      SurfaceSpecSupport.method("a.java", "Calc.add", "(int a) -> int"),
    ])
    target = Chiasmus::Graph::CodeGraph.new(defines: [
      SurfaceSpecSupport.method("b.cr", "Calc.add", "(a : Int32) -> Int32"),
    ])

    mappings = Chiasmus::Parity::Reconcile.mappings(source, target, typed_rules)
    report = Chiasmus::Parity::Surface.compare(source, target, mappings, typed_rules).first
    report.status.should eq("surface_match")
    report.return_type_match.should be_true
  end

  it "flags a return-type drift when types normalize differently" do
    source = Chiasmus::Graph::CodeGraph.new(defines: [
      SurfaceSpecSupport.method("a.java", "Calc.get", "() -> void"),
    ])
    target = Chiasmus::Graph::CodeGraph.new(defines: [
      SurfaceSpecSupport.method("b.cr", "Calc.get", "() -> Int32"),
    ])

    mappings = Chiasmus::Parity::Reconcile.mappings(source, target, typed_rules)
    report = Chiasmus::Parity::Surface.compare(source, target, mappings, typed_rules).first
    report.status.should eq("surface_match")
    report.return_type_match.should be_false
    report.details.should contain("return void->Int32")
  end

  it "marks a source method with no target surface as unmodeled" do
    source = Chiasmus::Graph::CodeGraph.new(defines: [
      SurfaceSpecSupport.method("a.java", "Calc.add", "(int a) -> int"),
    ])

    mappings = Chiasmus::Parity::Reconcile.mappings(source, Chiasmus::Graph::CodeGraph.new, rules)
    Chiasmus::Parity::Surface.compare(source, Chiasmus::Graph::CodeGraph.new, mappings).first.status.should eq("surface_unmodeled")
  end
end
