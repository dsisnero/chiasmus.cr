require "../spec_helper"
require "file_utils"
require "../../src/chiasmus/parity"
require "../../src/chiasmus/graph/facts"

private def with_parity_config_tmp_dir(&)
  dir = File.join(Dir.tempdir, "chiasmus-parity-config-spec-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

private def write_inventory(path : String, rows : Array(String)) : Nil
  File.write(path, rows.join("\n") + "\n")
end

describe Chiasmus::Parity do
  it "uses repo parity target_src defaults and configured equivalence rules during analysis" do
    with_parity_config_tmp_dir do |repo_root|
      Dir.mkdir_p(File.join(repo_root, "src", "chiasmus", "formalize"))
      File.write(
        File.join(repo_root, "src", "chiasmus", "formalize", "engine.cr"),
        "module Chiasmus\n  module Formalize\n    def self.run\n    end\n  end\nend\n"
      )

      inventory_path = File.join(repo_root, "inventory.tsv")
      write_inventory(inventory_path, [
        "# source_id\tkind\tstatus\tcrystal_refs\ttarget_symbol\ttest_refs\tnotes",
        "src/formalize/engine.ts::method::Formalize.run\tmethod\tported\tsrc/formalize/engine.cr:1\t-\t-\tPorted",
      ])

      Chiasmus::Utils::Config.ensure_repo_parity_config(
        vendor_src: "vendor/chiasmus",
        target_src: ["src/chiasmus"],
        equivalences: [
          Chiasmus::Utils::Config::RepoParityEquivalence.new(
            source_path: "src",
            target_path: "src/chiasmus",
            target_namespace: "Chiasmus"
          ),
        ],
        repo_root: repo_root
      )

      result = Chiasmus::Parity.analyze(
        inventory_path: inventory_path,
        root_dir: repo_root,
        crystal_dirs: [] of String,
        parser_mode: "regex"
      )

      row = result.rows.first
      result.parser_mode.should eq("regex")
      row.match_status.should eq("curated_alias")
      row.basis.should eq("normalized")
      row.crystal_path.should eq("src/chiasmus/formalize/engine.cr")
      row.crystal_name.should eq("Chiasmus::Formalize.run")
    end
  end

  it "uses configured path equivalence to resolve crystal_refs before marking them stale" do
    row = Chiasmus::Parity::InventoryRow.new(
      source_id: "src/formalize/engine.ts::method::Formalize.run",
      kind: "method",
      status: "ported",
      crystal_refs: "src/formalize/engine.cr:1",
      notes: "Ported"
    )
    symbol = Chiasmus::Parity::SymbolItem.new(
      id: "src/chiasmus/formalize/engine.cr::method::Chiasmus::Formalize.run",
      name: "Chiasmus::Formalize.run",
      kind: "method",
      file: "src/chiasmus/formalize/engine.cr",
      scope: "source",
      parser_mode: "regex"
    )
    parity_config = Chiasmus::Utils::Config::RepoParityConfig.new(
      vendor_src: "vendor/chiasmus",
      target_src: ["src/chiasmus"],
      equivalences: [
        Chiasmus::Utils::Config::RepoParityEquivalence.new(
          source_path: "src",
          target_path: "src/chiasmus",
          target_namespace: "Chiasmus"
        ),
      ]
    )

    matcher = Chiasmus::Parity::Matcher.new(
      [symbol],
      [] of Chiasmus::Parity::ConversionRule,
      parity_config: parity_config
    )
    result = matcher.analyze([row]).first

    result.match_status.should eq("curated_alias")
    result.crystal_path.should eq("src/chiasmus/formalize/engine.cr")
    result.notes.should eq("Ported")
  end

  it "uses repo parity vendor_src to align inventory source paths with source facts" do
    with_parity_config_tmp_dir do |repo_root|
      Dir.mkdir_p(File.join(repo_root, "src", "chiasmus", "formalize"))
      File.write(
        File.join(repo_root, "src", "chiasmus", "formalize", "engine.cr"),
        "module Chiasmus\n  module Formalize\n    def self.run\n    end\n  end\nend\n"
      )

      inventory_path = File.join(repo_root, "inventory.tsv")
      write_inventory(inventory_path, [
        "# source_id\tkind\tstatus\tcrystal_refs\ttarget_symbol\ttest_refs\tnotes",
        "src/formalize/engine.ts::method::Formalize.run\tmethod\tported\tsrc/formalize/engine.cr:1\t-\t-\tPorted",
      ])

      source_graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(
            file: "./vendor/chiasmus/src/formalize/engine.ts",
            name: "run",
            kind: Chiasmus::Graph::SymbolKind::Method,
            span: Chiasmus::Graph::Span.line_range(1),
            qualified_name: "Formalize.run"
          ),
        ],
        calls: [] of Chiasmus::Graph::CallsFact,
        imports: [] of Chiasmus::Graph::ImportsFact,
        exports: [] of Chiasmus::Graph::ExportsFact,
        contains: [] of Chiasmus::Graph::ContainsFact,
      )

      crystal_graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(
            file: "./src/chiasmus/formalize/engine.cr",
            name: "run",
            kind: Chiasmus::Graph::SymbolKind::Method,
            span: Chiasmus::Graph::Span.line_range(1),
            qualified_name: "Chiasmus::Formalize.run"
          ),
        ],
        calls: [] of Chiasmus::Graph::CallsFact,
        imports: [] of Chiasmus::Graph::ImportsFact,
        exports: [] of Chiasmus::Graph::ExportsFact,
        contains: [] of Chiasmus::Graph::ContainsFact,
      )

      source_facts_path = File.join(repo_root, "source.pl")
      crystal_facts_path = File.join(repo_root, "crystal.pl")
      File.write(source_facts_path, Chiasmus::Graph::Facts.graph_to_prolog(source_graph))
      File.write(crystal_facts_path, Chiasmus::Graph::Facts.graph_to_prolog(crystal_graph))

      Chiasmus::Utils::Config.ensure_repo_parity_config(
        vendor_src: "vendor/chiasmus",
        target_src: ["src/chiasmus"],
        equivalences: [
          Chiasmus::Utils::Config::RepoParityEquivalence.new(
            source_path: "src",
            target_path: "src/chiasmus",
            target_namespace: "Chiasmus"
          ),
        ],
        repo_root: repo_root
      )

      result = Chiasmus::Parity.analyze(
        inventory_path: inventory_path,
        root_dir: repo_root,
        crystal_dirs: [] of String,
        parser_mode: "regex",
        source_facts_path: source_facts_path,
        crystal_facts_path: crystal_facts_path
      )

      row = result.rows.first
      row.match_status.should eq("curated_alias")
      row.structural_status.should eq("structural_match")
      row.structural_details.should eq("-")
    end
  end
end
