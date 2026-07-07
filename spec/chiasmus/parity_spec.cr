require "spec"
require "../../src/chiasmus/parity"
require "../../src/chiasmus/graph/community"
require "../../src/chiasmus/graph/facts"
require "../../src/chiasmus/graph/insights"
require "../../src/chiasmus/graph/types"
require "file_utils"
require "../../src/chiasmus/utils/timeout"
require "../../src/chiasmus/solvers/prolog_solver"

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

describe Chiasmus::Parity::Structural do
  it "reports structural_match when normalized direct callees align" do
    source_graph = Chiasmus::Graph::CodeGraph.new(
      defines: [
        Chiasmus::Graph::DefinesFact.new(file: "src/config.ts", name: "loadConfig", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
        Chiasmus::Graph::DefinesFact.new(file: "src/config.ts", name: "parseConfig", kind: Chiasmus::Graph::SymbolKind::Function, line: 5),
        Chiasmus::Graph::DefinesFact.new(file: "src/fs.ts", name: "readFile", kind: Chiasmus::Graph::SymbolKind::Function, line: 9),
      ],
      calls: [
        Chiasmus::Graph::CallsFact.new(caller: "loadConfig", callee: "parseConfig"),
        Chiasmus::Graph::CallsFact.new(caller: "loadConfig", callee: "readFile"),
      ],
      exports: [] of Chiasmus::Graph::ExportsFact,
      contains: [] of Chiasmus::Graph::ContainsFact,
      imports: [] of Chiasmus::Graph::ImportsFact,
    )

    target_graph = Chiasmus::Graph::CodeGraph.new(
      defines: [
        Chiasmus::Graph::DefinesFact.new(file: "src/config.cr", name: "load_config", kind: Chiasmus::Graph::SymbolKind::Method, line: 1),
        Chiasmus::Graph::DefinesFact.new(file: "src/config.cr", name: "parse_config", kind: Chiasmus::Graph::SymbolKind::Method, line: 5),
        Chiasmus::Graph::DefinesFact.new(file: "src/fs.cr", name: "read_file", kind: Chiasmus::Graph::SymbolKind::Method, line: 9),
      ],
      calls: [
        Chiasmus::Graph::CallsFact.new(caller: "load_config", callee: "parse_config"),
        Chiasmus::Graph::CallsFact.new(caller: "load_config", callee: "read_file"),
      ],
      exports: [] of Chiasmus::Graph::ExportsFact,
      contains: [] of Chiasmus::Graph::ContainsFact,
      imports: [] of Chiasmus::Graph::ImportsFact,
    )

    report = Chiasmus::Parity::Structural.compare(
      source_graph,
      "loadConfig",
      target_graph,
      "load_config",
    )

    report.status.should eq("structural_match")
    report.missing_calls.should eq([] of String)
    report.extra_calls.should eq([] of String)
    report.matched_calls.should eq(["parse_config", "read_file"])
  end

  it "reports structural_drift when target drops a normalized direct callee" do
    source_graph = Chiasmus::Graph::CodeGraph.new(
      defines: [
        Chiasmus::Graph::DefinesFact.new(file: "src/config.ts", name: "loadConfig", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
        Chiasmus::Graph::DefinesFact.new(file: "src/config.ts", name: "parseConfig", kind: Chiasmus::Graph::SymbolKind::Function, line: 5),
        Chiasmus::Graph::DefinesFact.new(file: "src/fs.ts", name: "readFile", kind: Chiasmus::Graph::SymbolKind::Function, line: 9),
      ],
      calls: [
        Chiasmus::Graph::CallsFact.new(caller: "loadConfig", callee: "parseConfig"),
        Chiasmus::Graph::CallsFact.new(caller: "loadConfig", callee: "readFile"),
      ],
      exports: [] of Chiasmus::Graph::ExportsFact,
      contains: [] of Chiasmus::Graph::ContainsFact,
      imports: [] of Chiasmus::Graph::ImportsFact,
    )

    target_graph = Chiasmus::Graph::CodeGraph.new(
      defines: [
        Chiasmus::Graph::DefinesFact.new(file: "src/config.cr", name: "load_config", kind: Chiasmus::Graph::SymbolKind::Method, line: 1),
        Chiasmus::Graph::DefinesFact.new(file: "src/config.cr", name: "parse_config", kind: Chiasmus::Graph::SymbolKind::Method, line: 5),
      ],
      calls: [
        Chiasmus::Graph::CallsFact.new(caller: "load_config", callee: "parse_config"),
      ],
      exports: [] of Chiasmus::Graph::ExportsFact,
      contains: [] of Chiasmus::Graph::ContainsFact,
      imports: [] of Chiasmus::Graph::ImportsFact,
    )

    report = Chiasmus::Parity::Structural.compare(
      source_graph,
      "loadConfig",
      target_graph,
      "load_config",
    )

    report.status.should eq("structural_drift")
    report.missing_calls.should eq(["read_file"])
    report.extra_calls.should eq([] of String)
    report.matched_calls.should eq(["parse_config"])
  end

  it "reports structural_drift when target drops a contained child" do
    source_graph = Chiasmus::Graph::CodeGraph.new(
      defines: [
        Chiasmus::Graph::DefinesFact.new(file: "src/config.ts", name: "ConfigModule", kind: Chiasmus::Graph::SymbolKind::Module, line: 1),
        Chiasmus::Graph::DefinesFact.new(file: "src/config.ts", name: "parseConfig", kind: Chiasmus::Graph::SymbolKind::Function, line: 5),
        Chiasmus::Graph::DefinesFact.new(file: "src/fs.ts", name: "readFile", kind: Chiasmus::Graph::SymbolKind::Function, line: 9),
      ],
      calls: [] of Chiasmus::Graph::CallsFact,
      exports: [] of Chiasmus::Graph::ExportsFact,
      contains: [
        Chiasmus::Graph::ContainsFact.new(parent: "ConfigModule", child: "parseConfig"),
        Chiasmus::Graph::ContainsFact.new(parent: "ConfigModule", child: "readFile"),
      ],
      imports: [] of Chiasmus::Graph::ImportsFact,
    )

    target_graph = Chiasmus::Graph::CodeGraph.new(
      defines: [
        Chiasmus::Graph::DefinesFact.new(file: "src/config.cr", name: "ConfigModule", kind: Chiasmus::Graph::SymbolKind::Module, line: 1),
        Chiasmus::Graph::DefinesFact.new(file: "src/config.cr", name: "parse_config", kind: Chiasmus::Graph::SymbolKind::Method, line: 5),
      ],
      calls: [] of Chiasmus::Graph::CallsFact,
      exports: [] of Chiasmus::Graph::ExportsFact,
      contains: [
        Chiasmus::Graph::ContainsFact.new(parent: "ConfigModule", child: "parse_config"),
      ],
      imports: [] of Chiasmus::Graph::ImportsFact,
    )

    report = Chiasmus::Parity::Structural.compare(
      source_graph,
      "ConfigModule",
      target_graph,
      "ConfigModule",
    )

    report.status.should eq("structural_drift")
    report.missing_contains.should eq(["read_file"])
    report.extra_contains.should eq([] of String)
    report.matched_contains.should eq(["parse_config"])
  end

  it "reports structural_drift when the target symbol is missing from the fact graph" do
    source_graph = Chiasmus::Graph::CodeGraph.new(
      defines: [
        Chiasmus::Graph::DefinesFact.new(file: "src/config.ts", name: "loadConfig", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
      ],
      calls: [] of Chiasmus::Graph::CallsFact,
      exports: [] of Chiasmus::Graph::ExportsFact,
      contains: [] of Chiasmus::Graph::ContainsFact,
      imports: [] of Chiasmus::Graph::ImportsFact,
    )

    target_graph = Chiasmus::Graph::CodeGraph.new(
      defines: [] of Chiasmus::Graph::DefinesFact,
      calls: [] of Chiasmus::Graph::CallsFact,
      exports: [] of Chiasmus::Graph::ExportsFact,
      contains: [] of Chiasmus::Graph::ContainsFact,
      imports: [] of Chiasmus::Graph::ImportsFact,
    )

    report = Chiasmus::Parity::Structural.compare(
      source_graph,
      "loadConfig",
      target_graph,
      "load_config",
    )

    report.status.should eq("structural_drift")
    report.source_defined.should be_true
    report.target_defined.should be_false
  end

  it "reports structural_drift when export visibility differs" do
    source_graph = Chiasmus::Graph::CodeGraph.new(
      defines: [
        Chiasmus::Graph::DefinesFact.new(file: "src/config.ts", name: "loadConfig", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
      ],
      calls: [] of Chiasmus::Graph::CallsFact,
      exports: [
        Chiasmus::Graph::ExportsFact.new(file: "src/config.ts", name: "loadConfig"),
      ],
      contains: [] of Chiasmus::Graph::ContainsFact,
      imports: [] of Chiasmus::Graph::ImportsFact,
    )

    target_graph = Chiasmus::Graph::CodeGraph.new(
      defines: [
        Chiasmus::Graph::DefinesFact.new(file: "src/config.cr", name: "Demo.load_config", kind: Chiasmus::Graph::SymbolKind::Method, line: 1),
      ],
      calls: [] of Chiasmus::Graph::CallsFact,
      exports: [] of Chiasmus::Graph::ExportsFact,
      contains: [] of Chiasmus::Graph::ContainsFact,
      imports: [] of Chiasmus::Graph::ImportsFact,
    )

    report = Chiasmus::Parity::Structural.compare(
      source_graph,
      "loadConfig",
      target_graph,
      "Demo.load_config",
    )

    report.status.should eq("structural_drift")
    report.source_exported.should be_true
    report.target_exported.should be_false
  end

  it "reports structural_drift when entry-point status differs" do
    source_graph = Chiasmus::Graph::CodeGraph.new(
      defines: [
        Chiasmus::Graph::DefinesFact.new(file: "src/config.ts", name: "main", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
      ],
      calls: [] of Chiasmus::Graph::CallsFact,
      exports: [] of Chiasmus::Graph::ExportsFact,
      contains: [] of Chiasmus::Graph::ContainsFact,
      imports: [] of Chiasmus::Graph::ImportsFact,
    )

    target_graph = Chiasmus::Graph::CodeGraph.new(
      defines: [
        Chiasmus::Graph::DefinesFact.new(file: "src/main.cr", name: "Demo.main", kind: Chiasmus::Graph::SymbolKind::Method, line: 1),
      ],
      calls: [] of Chiasmus::Graph::CallsFact,
      exports: [] of Chiasmus::Graph::ExportsFact,
      contains: [] of Chiasmus::Graph::ContainsFact,
      imports: [] of Chiasmus::Graph::ImportsFact,
    )

    report = Chiasmus::Parity::Structural.compare(
      source_graph,
      "main",
      target_graph,
      "Demo.main",
      source_entry_points: ["main"],
      target_entry_points: [] of String,
    )

    report.status.should eq("structural_drift")
    report.source_entry_point.should be_true
    report.target_entry_point.should be_false
  end

  it "reports structural_drift when target drops a defining-file import" do
    source_graph = Chiasmus::Graph::CodeGraph.new(
      defines: [
        Chiasmus::Graph::DefinesFact.new(file: "src/config.ts", name: "loadConfig", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
      ],
      calls: [] of Chiasmus::Graph::CallsFact,
      imports: [
        Chiasmus::Graph::ImportsFact.new(file: "src/config.ts", name: "readFile", source: "./read-file"),
      ],
      exports: [] of Chiasmus::Graph::ExportsFact,
      contains: [] of Chiasmus::Graph::ContainsFact,
    )

    target_graph = Chiasmus::Graph::CodeGraph.new(
      defines: [
        Chiasmus::Graph::DefinesFact.new(file: "src/config.cr", name: "Demo.load_config", kind: Chiasmus::Graph::SymbolKind::Method, line: 1),
      ],
      calls: [] of Chiasmus::Graph::CallsFact,
      imports: [] of Chiasmus::Graph::ImportsFact,
      exports: [] of Chiasmus::Graph::ExportsFact,
      contains: [] of Chiasmus::Graph::ContainsFact,
    )

    report = Chiasmus::Parity::Structural.compare(
      source_graph,
      "loadConfig",
      target_graph,
      "Demo.load_config",
    )

    report.status.should eq("structural_drift")
    report.missing_imports.should eq(["read_file"])
    report.extra_imports.should eq([] of String)
    report.matched_imports.should eq([] of String)
  end

  it "does not borrow scoped call structure from a duplicate target symbol in another file" do
    source_facts = Chiasmus::Parity::StructuralFacts.new(
      graph: Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(file: "src/app.ts", name: "main", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
          Chiasmus::Graph::DefinesFact.new(file: "src/app.ts", name: "helper", kind: Chiasmus::Graph::SymbolKind::Function, line: 5),
          Chiasmus::Graph::DefinesFact.new(file: "src/app.ts", name: "leaf", kind: Chiasmus::Graph::SymbolKind::Function, line: 9),
        ],
        calls: [
          Chiasmus::Graph::CallsFact.new(caller: "main", callee: "helper"),
          Chiasmus::Graph::CallsFact.new(caller: "helper", callee: "leaf"),
        ],
        exports: [] of Chiasmus::Graph::ExportsFact,
        contains: [] of Chiasmus::Graph::ContainsFact,
        imports: [] of Chiasmus::Graph::ImportsFact,
      ),
      entry_points: ["main"],
      scoped_calls: [
        Chiasmus::Graph::IR::ScopedCallEdge.new("src/app.ts", "main", "helper"),
        Chiasmus::Graph::IR::ScopedCallEdge.new("src/app.ts", "helper", "leaf"),
      ],
      entry_point_files: [{"src/app.ts", "main"}],
    )

    target_facts = Chiasmus::Parity::StructuralFacts.new(
      graph: Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(file: "src/port.cr", name: "main", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
          Chiasmus::Graph::DefinesFact.new(file: "src/port.cr", name: "helper", kind: Chiasmus::Graph::SymbolKind::Function, line: 5),
          Chiasmus::Graph::DefinesFact.new(file: "src/port.cr", name: "leaf", kind: Chiasmus::Graph::SymbolKind::Function, line: 9),
          Chiasmus::Graph::DefinesFact.new(file: "src/util.cr", name: "helper", kind: Chiasmus::Graph::SymbolKind::Function, line: 3),
          Chiasmus::Graph::DefinesFact.new(file: "src/util.cr", name: "leaf", kind: Chiasmus::Graph::SymbolKind::Function, line: 7),
        ],
        calls: [
          Chiasmus::Graph::CallsFact.new(caller: "main", callee: "helper"),
          Chiasmus::Graph::CallsFact.new(caller: "helper", callee: "leaf"),
        ],
        exports: [] of Chiasmus::Graph::ExportsFact,
        contains: [] of Chiasmus::Graph::ContainsFact,
        imports: [] of Chiasmus::Graph::ImportsFact,
      ),
      entry_points: ["main"],
      scoped_calls: [
        Chiasmus::Graph::IR::ScopedCallEdge.new("src/port.cr", "main", "helper"),
        Chiasmus::Graph::IR::ScopedCallEdge.new("src/port.cr", "helper", "leaf"),
      ],
      entry_point_files: [{"src/port.cr", "main"}],
    )

    report = Chiasmus::Parity::Structural.compare(
      source_facts,
      "helper",
      target_facts,
      "helper",
      source_file: "src/app.ts",
      target_file: "src/util.cr",
    )

    report.status.should eq("structural_drift")
    report.matched_calls.should eq([] of String)
    report.missing_calls.should eq(["leaf"])
    report.extra_calls.should eq([] of String)
  end

  it "does not borrow graph-only call structure from a duplicate target symbol in another file when file hints are provided" do
    source_graph = Chiasmus::Graph::CodeGraph.new(
      defines: [
        Chiasmus::Graph::DefinesFact.new(file: "src/app.ts", name: "main", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
        Chiasmus::Graph::DefinesFact.new(file: "src/app.ts", name: "helper", kind: Chiasmus::Graph::SymbolKind::Function, line: 5),
        Chiasmus::Graph::DefinesFact.new(file: "src/app.ts", name: "leaf", kind: Chiasmus::Graph::SymbolKind::Function, line: 9),
      ],
      calls: [
        Chiasmus::Graph::CallsFact.new(caller: "main", callee: "helper"),
        Chiasmus::Graph::CallsFact.new(caller: "helper", callee: "leaf"),
      ],
      exports: [] of Chiasmus::Graph::ExportsFact,
      contains: [] of Chiasmus::Graph::ContainsFact,
      imports: [] of Chiasmus::Graph::ImportsFact,
    )

    target_graph = Chiasmus::Graph::CodeGraph.new(
      defines: [
        Chiasmus::Graph::DefinesFact.new(file: "src/port.cr", name: "main", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
        Chiasmus::Graph::DefinesFact.new(file: "src/port.cr", name: "helper", kind: Chiasmus::Graph::SymbolKind::Function, line: 5),
        Chiasmus::Graph::DefinesFact.new(file: "src/port.cr", name: "leaf", kind: Chiasmus::Graph::SymbolKind::Function, line: 9),
        Chiasmus::Graph::DefinesFact.new(file: "src/util.cr", name: "helper", kind: Chiasmus::Graph::SymbolKind::Function, line: 3),
        Chiasmus::Graph::DefinesFact.new(file: "src/util.cr", name: "leaf", kind: Chiasmus::Graph::SymbolKind::Function, line: 7),
      ],
      calls: [
        Chiasmus::Graph::CallsFact.new(caller: "main", callee: "helper"),
        Chiasmus::Graph::CallsFact.new(caller: "helper", callee: "leaf"),
      ],
      exports: [] of Chiasmus::Graph::ExportsFact,
      contains: [] of Chiasmus::Graph::ContainsFact,
      imports: [] of Chiasmus::Graph::ImportsFact,
    )

    report = Chiasmus::Parity::Structural.compare(
      source_graph,
      "helper",
      target_graph,
      "helper",
      source_file: "src/app.ts",
      target_file: "src/util.cr",
    )

    report.status.should eq("structural_drift")
    report.matched_calls.should eq([] of String)
    report.missing_calls.should eq(["leaf"])
    report.extra_calls.should eq([] of String)
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

  it "reads Crystal files concurrently during tree-sitter parity scanning" do
    dir = File.join(Dir.tempdir, "chiasmus-parity-tree-scan-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      Dir.mkdir_p(File.join(dir, "src"))
      Dir.mkdir_p(File.join(dir, "plans", "inventory"))

      {
        "alpha.cr" => "module Demo\n  def self.alpha\n  end\nend\n",
        "beta.cr"  => "module Demo\n  def self.beta\n  end\nend\n",
        "gamma.cr" => "module Demo\n  def self.gamma\n  end\nend\n",
      }.each do |name, content|
        File.write(File.join(dir, "src", name), content)
      end

      File.write(File.join(dir, "plans", "inventory", "port.tsv"), <<-TSV)
# source_id\tkind\tstatus\tcrystal_refs\tnotes
src/demo.ts::function::alpha\tfunction\tported\tsrc/alpha.cr:2\tPorted
TSV

      entered = Channel(String).new(3)
      release = Channel(Bool).new(3)
      result_channel = Channel(Chiasmus::Parity::AnalysisResult).new(1)

      begin
        Chiasmus::Parity::CrystalScanner.collect_file_max_concurrency_for_test = 2
        Chiasmus::Parity::CrystalScanner.set_before_collect_file_read_hook_for_test do |path|
          entered.send(File.basename(path))
          release.receive
        end

        spawn do
          result_channel.send(Chiasmus::Parity.analyze(
            inventory_path: File.join(dir, "plans", "inventory", "port.tsv"),
            root_dir: dir,
            crystal_dirs: ["src"],
            parser_mode: "tree-sitter"
          ))
        end

        first = Chiasmus::Utils::Timeout.with_timeout_async(500, entered)
        second = Chiasmus::Utils::Timeout.with_timeout_async(500, entered)
        first.should_not be_nil
        second.should_not be_nil

        select
        when entered.receive
          fail("expected tree-sitter parity scan to honor the bounded read limit")
        when timeout 50.milliseconds
        end

        release.send(true)
        third = Chiasmus::Utils::Timeout.with_timeout_async(500, entered)
        third.should_not be_nil
        2.times { release.send(true) }

        result = Chiasmus::Utils::Timeout.with_timeout_async(1_000, result_channel)
        result.should_not be_nil
        parity_result = result || raise "expected parity result"
        parity_result.parser_mode.should contain("tree-sitter")
      ensure
        Chiasmus::Parity::CrystalScanner.clear_before_collect_file_read_hook_for_test
        Chiasmus::Parity::CrystalScanner.clear_collect_file_max_concurrency_for_test
      end
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "uses tree-sitter directly for auto mode when Crystal tree-sitter is available" do
    dir = File.join(Dir.tempdir, "chiasmus-parity-auto-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)

    begin
      Dir.mkdir_p(File.join(dir, "src"))
      Dir.mkdir_p(File.join(dir, "plans", "inventory"))

      File.write(File.join(dir, "src", "demo.cr"), <<-CR)
module Demo
  def self.alpha
  end
end
CR

      File.write(File.join(dir, "plans", "inventory", "port.tsv"), <<-TSV)
# source_id\tkind\tstatus\tcrystal_refs\tnotes
src/demo.ts::function::alpha\tfunction\tported\tsrc/demo.cr:2\tPorted
TSV

      auto_result = Chiasmus::Parity.analyze(
        inventory_path: File.join(dir, "plans", "inventory", "port.tsv"),
        root_dir: dir,
        crystal_dirs: ["src"],
        parser_mode: "auto"
      )

      tree_result = Chiasmus::Parity.analyze(
        inventory_path: File.join(dir, "plans", "inventory", "port.tsv"),
        root_dir: dir,
        crystal_dirs: ["src"],
        parser_mode: "tree-sitter"
      )

      auto_result.rows.should eq(tree_result.rows)
      auto_result.parser_mode.should eq("tree-sitter")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "reports structural drift when source and crystal facts are provided" do
    dir = File.join(Dir.tempdir, "chiasmus-parity-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      Dir.mkdir_p(File.join(dir, "src"))
      Dir.mkdir_p(File.join(dir, "plans", "inventory"))

      File.write(File.join(dir, "src", "engine.cr"), <<-CR)
module Demo
  def self.build_gap_check
    parse_config
  end

  def self.parse_config
  end
end
CR

      File.write(File.join(dir, "plans", "inventory", "port.tsv"), <<-TSV)
# source_id\tkind\tstatus\tcrystal_refs\tnotes
src/config.ts::function::buildGapCheck\tfunction\tported\tsrc/engine.cr:2\tPorted as Demo.build_gap_check
TSV

      source_graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(file: "src/config.ts", name: "buildGapCheck", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
          Chiasmus::Graph::DefinesFact.new(file: "src/config.ts", name: "parseConfig", kind: Chiasmus::Graph::SymbolKind::Function, line: 5),
          Chiasmus::Graph::DefinesFact.new(file: "src/fs.ts", name: "readFile", kind: Chiasmus::Graph::SymbolKind::Function, line: 9),
        ],
        calls: [
          Chiasmus::Graph::CallsFact.new(caller: "buildGapCheck", callee: "parseConfig"),
          Chiasmus::Graph::CallsFact.new(caller: "buildGapCheck", callee: "readFile"),
        ],
        exports: [] of Chiasmus::Graph::ExportsFact,
        contains: [] of Chiasmus::Graph::ContainsFact,
        imports: [] of Chiasmus::Graph::ImportsFact,
      )

      crystal_graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(file: "src/engine.cr", name: "Demo.build_gap_check", kind: Chiasmus::Graph::SymbolKind::Method, line: 2),
          Chiasmus::Graph::DefinesFact.new(file: "src/engine.cr", name: "Demo.parse_config", kind: Chiasmus::Graph::SymbolKind::Method, line: 6),
        ],
        calls: [
          Chiasmus::Graph::CallsFact.new(caller: "Demo.build_gap_check", callee: "Demo.parse_config"),
        ],
        exports: [] of Chiasmus::Graph::ExportsFact,
        contains: [] of Chiasmus::Graph::ContainsFact,
        imports: [] of Chiasmus::Graph::ImportsFact,
      )

      source_facts_path = File.join(dir, "source.pl")
      crystal_facts_path = File.join(dir, "crystal.pl")
      File.write(source_facts_path, Chiasmus::Graph::Facts.graph_to_prolog(source_graph))
      File.write(crystal_facts_path, Chiasmus::Graph::Facts.graph_to_prolog(crystal_graph))

      output = IO::Memory.new
      error = IO::Memory.new
      exit_code = Chiasmus::Parity::CLI.run(
        [
          "--root", dir,
          "--inventory", File.join(dir, "plans", "inventory", "port.tsv"),
          "--crystal-dir", "src",
          "--parser", "regex",
          "--source-facts", source_facts_path,
          "--crystal-facts", crystal_facts_path,
        ],
        output,
        error
      )

      exit_code.should eq(0), error.to_s
      report = output.to_s
      report.should contain("structural_status")
      report.should contain("structural_details")
      report.should contain("structural_drift")
      report.should contain("missing_calls=read_file")
      report.should contain("matched_calls=parse_config")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "reports export drift when source and crystal facts disagree on public surface" do
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
src/config.ts::function::buildGapCheck\tfunction\tported\tsrc/engine.cr:2\tPorted as Demo.build_gap_check
TSV

      source_graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(file: "src/config.ts", name: "buildGapCheck", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
        ],
        calls: [] of Chiasmus::Graph::CallsFact,
        exports: [
          Chiasmus::Graph::ExportsFact.new(file: "src/config.ts", name: "buildGapCheck"),
        ],
        contains: [] of Chiasmus::Graph::ContainsFact,
        imports: [] of Chiasmus::Graph::ImportsFact,
      )

      crystal_graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(file: "src/engine.cr", name: "Demo.build_gap_check", kind: Chiasmus::Graph::SymbolKind::Method, line: 2),
        ],
        calls: [] of Chiasmus::Graph::CallsFact,
        exports: [] of Chiasmus::Graph::ExportsFact,
        contains: [] of Chiasmus::Graph::ContainsFact,
        imports: [] of Chiasmus::Graph::ImportsFact,
      )

      source_facts_path = File.join(dir, "source.pl")
      crystal_facts_path = File.join(dir, "crystal.pl")
      File.write(source_facts_path, Chiasmus::Graph::Facts.graph_to_prolog(source_graph))
      File.write(crystal_facts_path, Chiasmus::Graph::Facts.graph_to_prolog(crystal_graph))

      output = IO::Memory.new
      error = IO::Memory.new
      exit_code = Chiasmus::Parity::CLI.run(
        [
          "--root", dir,
          "--inventory", File.join(dir, "plans", "inventory", "port.tsv"),
          "--crystal-dir", "src",
          "--parser", "regex",
          "--source-facts", source_facts_path,
          "--crystal-facts", crystal_facts_path,
        ],
        output,
        error
      )

      exit_code.should eq(0), error.to_s
      report = output.to_s
      report.should contain("structural_drift")
      report.should contain("source_exported=true")
      report.should contain("target_exported=false")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "reports entry-point drift when source and crystal facts disagree on entry points" do
    dir = File.join(Dir.tempdir, "chiasmus-parity-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      Dir.mkdir_p(File.join(dir, "src"))
      Dir.mkdir_p(File.join(dir, "plans", "inventory"))

      File.write(File.join(dir, "src", "main.cr"), <<-CR)
module Demo
  def self.main
  end
end
CR

      File.write(File.join(dir, "plans", "inventory", "port.tsv"), <<-TSV)
# source_id\tkind\tstatus\tcrystal_refs\tnotes
src/main.ts::function::main\tfunction\tported\tsrc/main.cr:2\tPorted as Demo.main
TSV

      source_graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(file: "src/main.ts", name: "main", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
        ],
        calls: [] of Chiasmus::Graph::CallsFact,
        exports: [] of Chiasmus::Graph::ExportsFact,
        contains: [] of Chiasmus::Graph::ContainsFact,
        imports: [] of Chiasmus::Graph::ImportsFact,
      )

      crystal_graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(file: "src/main.cr", name: "Demo.main", kind: Chiasmus::Graph::SymbolKind::Method, line: 2),
        ],
        calls: [] of Chiasmus::Graph::CallsFact,
        exports: [] of Chiasmus::Graph::ExportsFact,
        contains: [] of Chiasmus::Graph::ContainsFact,
        imports: [] of Chiasmus::Graph::ImportsFact,
      )

      source_facts_path = File.join(dir, "source.pl")
      crystal_facts_path = File.join(dir, "crystal.pl")
      File.write(source_facts_path, Chiasmus::Graph::Facts.graph_to_prolog(source_graph, ["main"]))
      File.write(crystal_facts_path, Chiasmus::Graph::Facts.graph_to_prolog(crystal_graph, [] of String))

      output = IO::Memory.new
      error = IO::Memory.new
      exit_code = Chiasmus::Parity::CLI.run(
        [
          "--root", dir,
          "--inventory", File.join(dir, "plans", "inventory", "port.tsv"),
          "--crystal-dir", "src",
          "--parser", "regex",
          "--source-facts", source_facts_path,
          "--crystal-facts", crystal_facts_path,
        ],
        output,
        error
      )

      exit_code.should eq(0), error.to_s
      report = output.to_s
      report.should contain("structural_drift")
      report.should contain("source_entry_point=true")
      report.should contain("target_entry_point=false")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "reports import drift when source and crystal facts disagree on defining-file imports" do
    dir = File.join(Dir.tempdir, "chiasmus-parity-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      Dir.mkdir_p(File.join(dir, "src"))
      Dir.mkdir_p(File.join(dir, "plans", "inventory"))

      File.write(File.join(dir, "src", "config.cr"), <<-CR)
require "./other"

module Demo
  def self.load_config
  end
end
CR

      File.write(File.join(dir, "plans", "inventory", "port.tsv"), <<-TSV)
# source_id\tkind\tstatus\tcrystal_refs\tnotes
src/config.ts::function::loadConfig\tfunction\tported\tsrc/config.cr:4\tPorted as Demo.load_config
TSV

      source_graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(file: "src/config.ts", name: "loadConfig", kind: Chiasmus::Graph::SymbolKind::Function, line: 1),
        ],
        calls: [] of Chiasmus::Graph::CallsFact,
        imports: [
          Chiasmus::Graph::ImportsFact.new(file: "src/config.ts", name: "readFile", source: "./read-file"),
        ],
        exports: [] of Chiasmus::Graph::ExportsFact,
        contains: [] of Chiasmus::Graph::ContainsFact,
      )

      crystal_graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(file: "src/config.cr", name: "Demo.load_config", kind: Chiasmus::Graph::SymbolKind::Method, line: 4),
        ],
        calls: [] of Chiasmus::Graph::CallsFact,
        imports: [] of Chiasmus::Graph::ImportsFact,
        exports: [] of Chiasmus::Graph::ExportsFact,
        contains: [] of Chiasmus::Graph::ContainsFact,
      )

      source_facts_path = File.join(dir, "source.pl")
      crystal_facts_path = File.join(dir, "crystal.pl")
      File.write(source_facts_path, Chiasmus::Graph::Facts.graph_to_prolog(source_graph))
      File.write(crystal_facts_path, Chiasmus::Graph::Facts.graph_to_prolog(crystal_graph))

      output = IO::Memory.new
      error = IO::Memory.new
      exit_code = Chiasmus::Parity::CLI.run(
        [
          "--root", dir,
          "--inventory", File.join(dir, "plans", "inventory", "port.tsv"),
          "--crystal-dir", "src",
          "--parser", "regex",
          "--source-facts", source_facts_path,
          "--crystal-facts", crystal_facts_path,
        ],
        output,
        error
      )

      exit_code.should eq(0), error.to_s
      report = output.to_s
      report.should contain("structural_drift")
      report.should contain("missing_imports=read_file")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
  it "emits completion facts that identify reachable untested rows" do
    dir = File.join(Dir.tempdir, "chiasmus-parity-complete-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(File.join(dir, "src"))
    Dir.mkdir_p(File.join(dir, "spec"))
    Dir.mkdir_p(File.join(dir, "plans", "inventory"))

    begin
      File.write(File.join(dir, "src", "port.cr"), <<-CR)
def complete_me
end

def needs_test
end
CR

      File.write(File.join(dir, "spec", "complete_me_spec.cr"), <<-CR)
describe "complete_me" do
  it "is covered" do
    true.should be_true
  end
end
CR

      inventory_path = File.join(dir, "plans", "inventory", "port.tsv")
      File.write(inventory_path, <<-TSV)
# source_id	kind	status	crystal_refs	notes
src/app.ts::function::completeMe	function	ported	src/port.cr:1,spec/complete_me_spec.cr:1	Covered by spec ref
src/app.ts::function::needsTest	function	ported	src/port.cr:4	Missing explicit spec ref
src/app.ts::function::deadHelper	function	missing	-	Unreachable helper
TSV

      source_graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(file: "src/app.ts", name: "main", kind: Chiasmus::Graph::SymbolKind::Function, line: 1, end_line: 1),
          Chiasmus::Graph::DefinesFact.new(file: "src/app.ts", name: "completeMe", kind: Chiasmus::Graph::SymbolKind::Function, line: 2, end_line: 2),
          Chiasmus::Graph::DefinesFact.new(file: "src/app.ts", name: "needsTest", kind: Chiasmus::Graph::SymbolKind::Function, line: 3, end_line: 3),
          Chiasmus::Graph::DefinesFact.new(file: "src/app.ts", name: "deadHelper", kind: Chiasmus::Graph::SymbolKind::Function, line: 4, end_line: 4),
        ],
        calls: [
          Chiasmus::Graph::CallsFact.new(caller: "main", callee: "completeMe"),
          Chiasmus::Graph::CallsFact.new(caller: "main", callee: "needsTest"),
        ],
        imports: [] of Chiasmus::Graph::ImportsFact,
        exports: [] of Chiasmus::Graph::ExportsFact,
        contains: [] of Chiasmus::Graph::ContainsFact,
      )

      crystal_graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(file: "src/port.cr", name: "main", kind: Chiasmus::Graph::SymbolKind::Function, line: 1, end_line: 1),
          Chiasmus::Graph::DefinesFact.new(file: "src/port.cr", name: "complete_me", kind: Chiasmus::Graph::SymbolKind::Function, line: 2, end_line: 2),
          Chiasmus::Graph::DefinesFact.new(file: "src/port.cr", name: "needs_test", kind: Chiasmus::Graph::SymbolKind::Function, line: 3, end_line: 3),
        ],
        calls: [
          Chiasmus::Graph::CallsFact.new(caller: "main", callee: "complete_me"),
          Chiasmus::Graph::CallsFact.new(caller: "main", callee: "needs_test"),
        ],
        imports: [] of Chiasmus::Graph::ImportsFact,
        exports: [] of Chiasmus::Graph::ExportsFact,
        contains: [] of Chiasmus::Graph::ContainsFact,
      )

      source_facts_path = File.join(dir, "source.pl")
      crystal_facts_path = File.join(dir, "crystal.pl")
      File.write(source_facts_path, Chiasmus::Graph::Facts.graph_to_prolog(source_graph, ["main"]))
      File.write(crystal_facts_path, Chiasmus::Graph::Facts.graph_to_prolog(crystal_graph, ["main"]))

      output = IO::Memory.new
      error = IO::Memory.new
      exit_code = Chiasmus::Parity::CLI.run(
        [
          "--inventory", inventory_path,
          "--root", dir,
          "--crystal-dir", "src",
          "--parser", "regex",
          "--source-facts", source_facts_path,
          "--crystal-facts", crystal_facts_path,
          "--format", "completion-facts",
        ],
        output,
        error
      )

      exit_code.should eq(0), error.to_s
      program = output.to_s
      program.should contain("complete(Id) :-")
      program.should contain("incomplete(Id) :-")

      solver = Chiasmus::Solvers::PrologSolver.new
      begin
        incomplete = solver.solve(program, "incomplete(Id)")
        incomplete.should be_a(Chiasmus::Solvers::SuccessResult)
        incomplete_ids = incomplete.as(Chiasmus::Solvers::SuccessResult).answers.compact_map { |answer| answer.bindings["Id"]? }
        incomplete_ids.should eq(["src/app.ts::function::needsTest"])

        complete = solver.solve(program, "complete(Id)")
        complete.should be_a(Chiasmus::Solvers::SuccessResult)
        complete_ids = complete.as(Chiasmus::Solvers::SuccessResult).answers.compact_map { |answer| answer.bindings["Id"]? }
        complete_ids.should eq(["src/app.ts::function::completeMe"])
      ensure
        solver.dispose
      end
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
