require "../../spec_helper"
require "../../../src/chiasmus/parity/rules"

RULES_SPEC_PDFBOX_YAML = <<-YAML
version: 1
source_language: java
target_language: crystal
source:
  strip_namespace:
    - "org.apache.pdfbox."
    - "org.apache.fontbox."
  strip_prefix:
    - COS
    - PD
  strip_accessor: true
target:
  strip_namespace: []
  strip_prefix: []
  strip_accessor: false
renames:
  - source: DefaultResourceCache
    target: ResourceCache
consolidate:
  - source: "Operator*"
    target: process_operator
    reason: operator classes dispatch via process_operator
YAML

describe Chiasmus::Parity::Rules do
  rules = Chiasmus::Parity::Rules::RuleSet.from_yaml(RULES_SPEC_PDFBOX_YAML)
  normalizer = Chiasmus::Parity::Rules::Normalizer.new(rules)
  source_side = Chiasmus::Parity::Rules::Normalizer::Side::Source
  target_side = Chiasmus::Parity::Rules::Normalizer::Side::Target

  it "loads language and side configuration from YAML" do
    rules.source_language.should eq("java")
    rules.target_language.should eq("crystal")
    rules.source.strip_prefix.should eq(["COS", "PD"])
    rules.source.strip_accessor?.should be_true
    rules.target.strip_accessor?.should be_false
  end

  it "strips configured class-name prefixes before canonicalizing" do
    normalizer.normalize(rules.source, "COSBase").should eq("Base")
    normalizer.canonical(source_side, "COSBase").should eq("base")
    normalizer.canonical(source_side, "PDDocumentInformation").should eq("document_information")
  end

  it "strips accessor prefixes into a base name" do
    normalizer.canonical(source_side, "getOpenAction").should eq("open_action")
    normalizer.canonical(source_side, "setPage").should eq("page")
    # Lowercase follower is not an accessor; do not mangle genuine names.
    normalizer.canonical(source_side, "island").should eq("island")
  end

  it "applies explicit renames after normalization" do
    canonical, basis = normalizer.canonical_with_basis(source_side, "DefaultResourceCache")
    canonical.should eq("resource_cache")
    basis.should eq("renamed")
  end

  it "applies consolidation globs across matching source families" do
    canonical, basis = normalizer.canonical_with_basis(source_side, "OperatorSetStrokingColorN")
    canonical.should eq("process_operator")
    basis.should eq("consolidated")
  end

  it "normalizes target-side qualified names" do
    normalizer.canonical(target_side, "Base").should eq("base")
    normalizer.canonical(target_side, "Cos::Stream").should eq("stream")
    normalizer.canonical(target_side, "process_operator").should eq("process_operator")
  end

  it "reports a direct basis when no rule applies" do
    canonical, basis = normalizer.canonical_with_basis(source_side, "PDDocument")
    canonical.should eq("document")
    basis.should eq("direct")
  end

  it "prefers the shortest prefix that leaves a valid remainder" do
    prefix_rules = Chiasmus::Parity::Rules::RuleSet.from_yaml(<<-YAML)
    version: 1
    source:
      strip_prefix: [COS, PD, FDF, PDF]
    YAML
    normalizer = Chiasmus::Parity::Rules::Normalizer.new(prefix_rules)

    # `PDF` would leave `ontLike`; `PD` leaves `FontLike`.
    normalizer.normalize(prefix_rules.source, "PDFontLike").should eq("FontLike")
    # `PDF` leaves a valid `DocEncoding`, so the longer prefix wins here.
    normalizer.normalize(prefix_rules.source, "PDFDocEncoding").should eq("DocEncoding")
    normalizer.normalize(prefix_rules.source, "PDDocumentInformation").should eq("DocumentInformation")
    normalizer.normalize(prefix_rules.source, "COSBase").should eq("Base")
  end

  it "resolves owner aliases transitively to a fixpoint" do
    alias_rules = Chiasmus::Parity::Rules::RuleSet.from_yaml(<<-YAML)
    version: 1
    owner_aliases:
      - source: pdfwriter
        target: pdf_writer
      - source: pdf_writer
        target: writer
    YAML
    normalizer = Chiasmus::Parity::Rules::Normalizer.new(alias_rules)

    normalizer.resolve_alias("pdfwriter").should eq("writer")
    normalizer.resolve_alias("pdf_writer").should eq("writer")
    normalizer.resolve_alias("writer").should eq("writer")
    normalizer.resolve_alias("unrelated").should eq("unrelated")
  end
end
