require "spec"
require "../../src/chiasmus/parity"
require "file_utils"

describe Chiasmus::Parity::Naming do
  it "normalizes camelCase and snake_case to the same key" do
    Chiasmus::Parity::Naming.normalized_key("buildGapCheck").should eq("build_gap_check")
    Chiasmus::Parity::Naming.normalized_key("build_gap_check").should eq("build_gap_check")
  end

  it "normalizes escaped and symbolic variants used by language refiners" do
    Chiasmus::Parity::Naming.normalized_key("selectEscaped").should eq("select")
    Chiasmus::Parity::Naming.normalized_key("select_escaped").should eq("select")
    Chiasmus::Parity::Naming.normalized_key("A+B").should eq("a_plus_b")
  end

  it "extracts owner names from qualified methods" do
    Chiasmus::Parity::Naming.normalized_owner("FormalizationEngine.constructor").should eq("formalization_engine")
    Chiasmus::Parity::Naming.normalized_owner("Chiasmus::Formalize::lint_spec").should eq("chiasmus.formalize")
  end
end

describe Chiasmus::Parity::Matcher do
  it "classifies snake_case Crystal methods as curated aliases for camelCase upstream functions" do
    row = Chiasmus::Parity::InventoryRow.new(
      source_id: "src/p5-validation.ts::function::buildGapCheck",
      kind: "function",
      status: "ported",
      crystal_refs: "src/p5_validation.cr:37",
      notes: "Ported as build_gap_check"
    )
    symbol = Chiasmus::Parity::SymbolItem.new(
      id: "src/p5_validation.cr::method::build_gap_check",
      name: "build_gap_check",
      kind: "method",
      file: "src/p5_validation.cr",
      scope: "source",
      parser_mode: "regex"
    )

    matcher = Chiasmus::Parity::Matcher.new([symbol], [] of Chiasmus::Parity::ConversionRule)
    result = matcher.analyze([row]).first

    result.match_status.should eq("curated_alias")
    result.basis.should eq("normalized")
    result.crystal_name.should eq("build_gap_check")
  end

  it "uses conversion rules to report intentional divergence" do
    row = Chiasmus::Parity::InventoryRow.new(
      source_id: "src/graph/adapter-registry.ts::function::registerFromModule",
      kind: "function",
      status: "intentional_divergence",
      crystal_refs: "-",
      notes: "-"
    )
    rule = Chiasmus::Parity::ConversionRule.new(
      from_language: "typescript",
      to_language: "crystal",
      upstream_kind: "registerFromModule",
      crystal_kind: "adapter manifest discovery",
      notes: "Node.js dynamic module loading replaced by manifest discovery"
    )

    matcher = Chiasmus::Parity::Matcher.new([] of Chiasmus::Parity::SymbolItem, [rule])
    result = matcher.analyze([row]).first

    result.match_status.should eq("intentional_divergence")
    result.crystal_name.should eq("adapter manifest discovery")
    result.basis.should eq("conversion_rule")
  end

  it "keeps intentional divergence rows intentional even without a conversion rule" do
    row = Chiasmus::Parity::InventoryRow.new(
      source_id: "src/skills/bm25.ts::function::search",
      kind: "function",
      status: "intentional_divergence",
      crystal_refs: "lib/bm25/src/bm25/search.cr:55",
      notes: "Replaced by Bm25::SearchEngine#search"
    )
    symbol = Chiasmus::Parity::SymbolItem.new(
      id: "lib/bm25/src/bm25/search.cr::method::search",
      name: "search",
      kind: "method",
      file: "lib/bm25/src/bm25/search.cr",
      scope: "source",
      parser_mode: "regex"
    )

    matcher = Chiasmus::Parity::Matcher.new([symbol], [] of Chiasmus::Parity::ConversionRule)
    result = matcher.analyze([row]).first

    result.match_status.should eq("intentional_divergence")
    result.crystal_name.should eq("search")
    result.crystal_path.should eq("lib/bm25/src/bm25/search.cr")
  end

  it "reports stale crystal_refs explicitly and keeps the best fallback candidate" do
    row = Chiasmus::Parity::InventoryRow.new(
      source_id: "tests/mcp-server.test.ts::test::chiasmus_review",
      kind: "test",
      status: "ported",
      crystal_refs: "spec/chiasmus/mcp_server/review_spec.cr",
      notes: "Ported"
    )
    symbol = Chiasmus::Parity::SymbolItem.new(
      id: "spec/chiasmus/review_spec.cr::test::chiasmus_review",
      name: "chiasmus_review",
      kind: "test",
      file: "spec/chiasmus/review_spec.cr",
      scope: "test",
      parser_mode: "regex"
    )

    matcher = Chiasmus::Parity::Matcher.new([symbol], [] of Chiasmus::Parity::ConversionRule)
    result = matcher.analyze([row]).first

    result.match_status.should eq("stale_ref_path")
    result.crystal_path.should eq("spec/chiasmus/review_spec.cr")
    result.notes.should contain("stale crystal_refs: spec/chiasmus/mcp_server/review_spec.cr")
  end
end

describe Chiasmus::Parity::CLI do
  it "produces a TSV report for a temp mini-repo" do
    dir = File.join(Dir.tempdir, "chiasmus-parity-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      Dir.mkdir_p(File.join(dir, "src"))
      Dir.mkdir_p(File.join(dir, "plans", "inventory"))

      File.write(File.join(dir, "src", "engine.cr"), <<-CR)
module Demo
  def self.build_gap_check
  end
end
CR

      File.write(File.join(dir, "plans", "inventory", "port.tsv"), <<-TSV)
# source_id\tkind\tstatus\tcrystal_refs\tnotes
src/p5-validation.ts::function::buildGapCheck\tfunction\tported\tsrc/engine.cr:2\tPorted as build_gap_check
src/graph/adapter-registry.ts::function::registerFromModule\tfunction\tintentional_divergence\t-\t-
TSV

      File.write(File.join(dir, "plans", "inventory", "rules.tsv"), <<-TSV)
typescript\tcrystal\tregisterFromModule\tadapter manifest discovery\tNode.js dynamic module loading replaced by manifest discovery
TSV

      output = IO::Memory.new
      error = IO::Memory.new
      exit_code = Chiasmus::Parity::CLI.run(
        [
          "--root", dir,
          "--inventory", File.join(dir, "plans", "inventory", "port.tsv"),
          "--rules", File.join(dir, "plans", "inventory", "rules.tsv"),
          "--crystal-dir", "src",
          "--parser", "regex",
        ],
        output,
        error
      )

      exit_code.should eq(0), error.to_s
      report = output.to_s
      report.should contain("# parser_mode=regex")
      report.should contain("src/p5-validation.ts::function::buildGapCheck\tfunction\tported\tcurated_alias")
      report.should contain("src/graph/adapter-registry.ts::function::registerFromModule\tfunction\tintentional_divergence\tintentional_divergence")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "ignores AppleDouble Crystal files while scanning" do
    dir = File.join(Dir.tempdir, "chiasmus-parity-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      Dir.mkdir_p(File.join(dir, "src"))
      Dir.mkdir_p(File.join(dir, "plans", "inventory"))

      File.write(File.join(dir, "src", "engine.cr"), <<-CR)
module Demo
  def self.real_symbol
  end
end
CR

      File.write(File.join(dir, "src", "._engine.cr"), <<-CR)
module Noise
  def self.fake_symbol
  end
end
CR

      File.write(File.join(dir, "plans", "inventory", "port.tsv"), <<-TSV)
# source_id\tkind\tstatus\tcrystal_refs\tnotes
src/demo.ts::function::realSymbol\tfunction\tported\tsrc/engine.cr:2\tPorted
TSV

      result = Chiasmus::Parity.analyze(
        inventory_path: File.join(dir, "plans", "inventory", "port.tsv"),
        root_dir: dir,
        crystal_dirs: ["src"],
        parser_mode: "regex"
      )

      result.rows.first.crystal_name.should eq("Demo.real_symbol")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
