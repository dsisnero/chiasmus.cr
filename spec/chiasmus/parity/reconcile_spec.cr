require "../../spec_helper"
require "../../../src/chiasmus/parity/reconcile"

module ReconcileSpecSupport
  RULES_YAML = <<-YAML
  version: 1
  source_language: java
  target_language: crystal
  source:
    strip_prefix:
      - COS
      - PD
    strip_accessor: true
  renames:
    - source: DefaultResourceCache
      target: ResourceCache
  consolidate:
    - source: "Operator*"
      target: process_operator
  YAML

  OWNER_RULES_YAML = <<-YAML
  version: 1
  source_language: java
  target_language: crystal
  match_owner: true
  source:
    strip_prefix:
      - COS
      - PD
  target:
    strip_prefix:
      - COS
      - PD
  YAML

  def self.fact(file : String, name : String, kind : Chiasmus::Graph::SymbolKind, qualified : String? = nil, signature : String? = nil) : Chiasmus::Graph::DefinesFact
    Chiasmus::Graph::DefinesFact.new(
      file: file,
      name: name,
      kind: kind,
      span: Chiasmus::Graph::Span.line_range(1, 1),
      qualified_name: qualified,
      signature: signature,
    )
  end
end

describe Chiasmus::Parity::Reconcile do
  rules = Chiasmus::Parity::Rules::RuleSet.from_yaml(ReconcileSpecSupport::RULES_YAML)
  owner_rules = Chiasmus::Parity::Rules::RuleSet.from_yaml(ReconcileSpecSupport::OWNER_RULES_YAML)
  inherited_rules = Chiasmus::Parity::Rules::RuleSet.from_yaml("version: 1\nmatch_owner: true\nmatch_inherited: true\n")
  klass = Chiasmus::Graph::SymbolKind::Class
  method = Chiasmus::Graph::SymbolKind::Method

  it "matches a prefixed source class to its target and records the canonical key" do
    source = Chiasmus::Graph::CodeGraph.new(defines: [
      ReconcileSpecSupport.fact("COSBase.java", "COSBase", klass, "COSBase"),
    ])
    target = Chiasmus::Graph::CodeGraph.new(defines: [
      ReconcileSpecSupport.fact("src/pdfbox/cos/base.cr", "Base", klass, "Base"),
    ])

    mapping = Chiasmus::Parity::Reconcile.mappings(source, target, rules).first
    mapping.status.should eq("matched")
    mapping.canonical.should eq("base")
    mapping.target_name.should eq("Base")
    mapping.basis.should eq("direct")
  end

  it "flags a name collision as ambiguous instead of silently matching" do
    source = Chiasmus::Graph::CodeGraph.new(defines: [
      ReconcileSpecSupport.fact("COSStream.java", "COSStream", klass, "COSStream"),
    ])
    target = Chiasmus::Graph::CodeGraph.new(defines: [
      ReconcileSpecSupport.fact("src/pdfbox/cos/stream.cr", "Stream", klass, "Cos::Stream"),
      ReconcileSpecSupport.fact("src/pdfbox/debugger/stream.cr", "Stream", klass, "Debugger::Stream"),
    ])

    Chiasmus::Parity::Reconcile.mappings(source, target, rules).first.status.should eq("ambiguous")
  end

  it "resolves a name collision using owner-aware matching when enabled" do
    source = Chiasmus::Graph::CodeGraph.new(defines: [
      ReconcileSpecSupport.fact("vendor/pdfbox/pdfbox/src/main/java/org/apache/pdfbox/cos/COSStream.java", "COSStream", klass, "COSStream"),
    ])
    target = Chiasmus::Graph::CodeGraph.new(
      defines: [
        ReconcileSpecSupport.fact("src/pdfbox/cos.cr", "Stream", klass),
        ReconcileSpecSupport.fact("src/pdfbox/pdmodel/pd_stream.cr", "PDStream", klass),
      ],
      contains: [
        Chiasmus::Graph::ContainsFact.new(parent: "Pdfbox::Cos", child: "Stream"),
        Chiasmus::Graph::ContainsFact.new(parent: "Pdfbox::PdModel", child: "PDStream"),
      ],
    )

    mapping = Chiasmus::Parity::Reconcile.mappings(source, target, owner_rules).first
    mapping.status.should eq("matched")
    mapping.basis.should eq("owner")
    mapping.target_name.should eq("Stream")
  end

  it "matches a module-qualified Crystal owner to the Java owner leaf" do
    source = Chiasmus::Graph::CodeGraph.new(defines: [
      ReconcileSpecSupport.fact("io/MemoryUsageSetting.java", "setupMainMemoryOnly", method, "MemoryUsageSetting.setupMainMemoryOnly"),
    ])
    target = Chiasmus::Graph::CodeGraph.new(defines: [
      ReconcileSpecSupport.fact("src/pdfbox/io.cr", "setup_main_memory_only", method, "Pdfbox::IO.MemoryUsageSetting.setup_main_memory_only"),
    ])

    mapping = Chiasmus::Parity::Reconcile.mappings(source, target, owner_rules).first
    mapping.status.should eq("matched")
    mapping.basis.should eq("owner")
    mapping.target_name.should eq("Pdfbox::IO.MemoryUsageSetting.setup_main_memory_only")
  end

  it "breaks same-owner ties by exact kind" do
    function = Chiasmus::Graph::SymbolKind::Function
    source = Chiasmus::Graph::CodeGraph.new(defines: [
      ReconcileSpecSupport.fact("a.java", "handle", function, "Widget.handle"),
    ])
    target = Chiasmus::Graph::CodeGraph.new(defines: [
      ReconcileSpecSupport.fact("b.cr", "handle", method, "Widget.handle"),
      ReconcileSpecSupport.fact("b.cr", "handle", function, "Widget.handle"),
    ])

    mapping = Chiasmus::Parity::Reconcile.mappings(source, target, owner_rules).first
    mapping.status.should eq("matched")
    mapping.target_kind.should eq("function")
  end

  it "flags an inherited base member across concrete owners as ambiguous (not unmapped)" do
    source = Chiasmus::Graph::CodeGraph.new(defines: [
      ReconcileSpecSupport.fact("PDAbstractContentStream.java", "beginText", method, "PDAbstractContentStream.beginText", "() -> void"),
    ])
    target = Chiasmus::Graph::CodeGraph.new(defines: [
      ReconcileSpecSupport.fact("page_content_stream.cr", "begin_text", method, "PageContentStream.begin_text", "() -> Nil"),
      ReconcileSpecSupport.fact("form_content_stream.cr", "begin_text", method, "FormContentStream.begin_text", "() -> Nil"),
    ])

    mapping = Chiasmus::Parity::Reconcile.mappings(source, target, inherited_rules).first
    mapping.status.should eq("ambiguous")
    mapping.basis.should eq("member")
  end

  it "does not fall back for a single unrelated owner (coincidence)" do
    source = Chiasmus::Graph::CodeGraph.new(defines: [
      ReconcileSpecSupport.fact("IndexedColorant.java", "getColor", method, "IndexedColorant.getColor", "() -> int"),
    ])
    target = Chiasmus::Graph::CodeGraph.new(defines: [
      ReconcileSpecSupport.fact("blend_mode.cr", "color", method, "BlendMode.color", "() -> Int32"),
    ])

    Chiasmus::Parity::Reconcile.mappings(source, target, inherited_rules).first.status.should eq("unmapped_source")
  end

  it "does not match inherited members when signature arity disagrees" do
    source = Chiasmus::Graph::CodeGraph.new(defines: [
      ReconcileSpecSupport.fact("Base.java", "read", method, "Base.read", "(int n) -> int"),
    ])
    target = Chiasmus::Graph::CodeGraph.new(defines: [
      ReconcileSpecSupport.fact("impl.cr", "read", method, "Impl.read", "(a, b) -> Int32"),
    ])

    Chiasmus::Parity::Reconcile.mappings(source, target, inherited_rules).first.status.should eq("unmapped_source")
  end

  it "reconciles via an explicit rename rule" do
    source = Chiasmus::Graph::CodeGraph.new(defines: [
      ReconcileSpecSupport.fact("DefaultResourceCache.java", "DefaultResourceCache", klass, "DefaultResourceCache"),
    ])
    target = Chiasmus::Graph::CodeGraph.new(defines: [
      ReconcileSpecSupport.fact("src/pdfbox/io/resource_cache.cr", "ResourceCache", klass, "ResourceCache"),
    ])

    mapping = Chiasmus::Parity::Reconcile.mappings(source, target, rules).first
    mapping.status.should eq("matched")
    mapping.basis.should eq("renamed")
  end

  it "reconciles many operator classes into one dispatch method across kinds" do
    source = Chiasmus::Graph::CodeGraph.new(defines: [
      ReconcileSpecSupport.fact("OperatorDrawObject.java", "OperatorDrawObject", klass, "OperatorDrawObject"),
    ])
    target = Chiasmus::Graph::CodeGraph.new(defines: [
      ReconcileSpecSupport.fact("src/pdfbox/contentstream/engine.cr", "process_operator", method, "process_operator"),
    ])

    mapping = Chiasmus::Parity::Reconcile.mappings(source, target, rules).first
    mapping.status.should eq("matched")
    mapping.basis.should eq("consolidated")
    mapping.target_kind.should eq("method")
  end

  it "marks a genuinely missing entity as unmapped_source" do
    source = Chiasmus::Graph::CodeGraph.new(defines: [
      ReconcileSpecSupport.fact("MissingThing.java", "MissingThing", klass, "MissingThing"),
    ])

    mapping = Chiasmus::Parity::Reconcile.mappings(source, Chiasmus::Graph::CodeGraph.new, rules).first
    mapping.status.should eq("unmapped_source")
    mapping.target_id.should be_nil
  end

  it "does not match a class to an incompatible target kind" do
    source = Chiasmus::Graph::CodeGraph.new(defines: [
      ReconcileSpecSupport.fact("COSBase.java", "COSBase", klass, "COSBase"),
    ])
    target = Chiasmus::Graph::CodeGraph.new(defines: [
      ReconcileSpecSupport.fact("src/pdfbox/cos/base.cr", "Base", method, "Base"),
    ])

    Chiasmus::Parity::Reconcile.mappings(source, target, rules).first.status.should eq("unmapped_source")
  end
end
