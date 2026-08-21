require "../spec_helper"
require "file_utils"

module ParityTargetSymbolSpecHelpers
  extend self

  def parity_fixture_repo(name : String) : String
    dir = File.join(Dir.tempdir, "chiasmus-parity-fixture-#{name}-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    dir
  end

  def parity_fixture_root : String
    File.expand_path("../testdata/parity", __DIR__)
  end

  def copy_fixture(repo_dir : String, source_rel : String, target_rel : String) : Nil
    source = File.join(parity_fixture_root, source_rel)
    target = File.join(repo_dir, target_rel)
    Dir.mkdir_p(File.dirname(target))
    FileUtils.cp(source, target)
  end

  def extract_fixture_graph(repo_dir : String, rel_paths : Array(String), cache_dir : String) : Chiasmus::Graph::CodeGraph
    repo_key = Chiasmus::Graph::GraphCache.default_repo_key(repo_dir)
    files = rel_paths.map do |rel_path|
      absolute = File.join(repo_dir, rel_path)
      Chiasmus::Graph::SourceFile.new(path: rel_path, content: File.read(absolute))
    end

    Chiasmus::Graph::Extractor.extract_graph(files, cache_dir: cache_dir, repo_key: repo_key)
  end

  def write_facts(path : String, graph : Chiasmus::Graph::CodeGraph) : Nil
    File.write(path, Chiasmus::Graph::Facts.graph_to_prolog(graph))
  end
end

describe Chiasmus::Parity do
  it "uses target_symbol for a copied vendor function-only fixture" do
    dir = ParityTargetSymbolSpecHelpers.parity_fixture_repo("function-copy")
    cache_dir = File.join(dir, "cache")
    begin
      ParityTargetSymbolSpecHelpers.copy_fixture(dir, "typescript/prolog-input.ts", "src/formalize/prolog-input.ts")
      ParityTargetSymbolSpecHelpers.copy_fixture(dir, "crystal/prolog_input.cr", "src/prolog_input.cr")
      Dir.mkdir_p(File.join(dir, "plans", "inventory"))

      File.write(File.join(dir, "plans", "inventory", "port.tsv"), <<-TSV)
# source_id	kind	status	crystal_refs	target_symbol	test_refs	notes
src/formalize/prolog-input.ts::function::extractPrologQuery	function	ported	src/prolog_input.cr:4	SpecParity.extract_prolog_query	-	Ported as SpecParity.extract_prolog_query
TSV

      source_graph = ParityTargetSymbolSpecHelpers.extract_fixture_graph(dir, ["src/formalize/prolog-input.ts"], cache_dir)
      crystal_graph = ParityTargetSymbolSpecHelpers.extract_fixture_graph(dir, ["src/prolog_input.cr"], cache_dir)
      Chiasmus::Graph::GraphCache.flush_async_writes

      source_facts_path = File.join(dir, "source.pl")
      crystal_facts_path = File.join(dir, "crystal.pl")
      ParityTargetSymbolSpecHelpers.write_facts(source_facts_path, source_graph)
      ParityTargetSymbolSpecHelpers.write_facts(crystal_facts_path, crystal_graph)

      result = Chiasmus::Parity.analyze(
        inventory_path: File.join(dir, "plans", "inventory", "port.tsv"),
        root_dir: dir,
        crystal_dirs: ["src"],
        parser_mode: "tree-sitter",
        source_facts_path: source_facts_path,
        crystal_facts_path: crystal_facts_path,
      )

      row = result.rows.first
      row.match_status.should eq("curated_alias")
      row.crystal_name.should eq("SpecParity.extract_prolog_query")
      row.basis.should eq("target_symbol")
    ensure
      Chiasmus::Graph::GraphCache.flush_async_writes
      Chiasmus::Graph::GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(dir)
    end
  end

  it "reports structural_match for a vendor-derived function-only fixture" do
    dir = ParityTargetSymbolSpecHelpers.parity_fixture_repo("function-derived")
    cache_dir = File.join(dir, "cache")
    begin
      ParityTargetSymbolSpecHelpers.copy_fixture(dir, "typescript/prolog-input-min.ts", "src/formalize/prolog-input.ts")
      ParityTargetSymbolSpecHelpers.copy_fixture(dir, "crystal/prolog_input_min.cr", "src/prolog_input.cr")
      Dir.mkdir_p(File.join(dir, "plans", "inventory"))

      File.write(File.join(dir, "plans", "inventory", "port.tsv"), <<-TSV)
# source_id	kind	status	crystal_refs	target_symbol	test_refs	notes
src/formalize/prolog-input.ts::function::extractPrologQuery	function	ported	src/prolog_input.cr:1	extract_prolog_query	-	Ported as extract_prolog_query
TSV

      source_graph = ParityTargetSymbolSpecHelpers.extract_fixture_graph(dir, ["src/formalize/prolog-input.ts"], cache_dir)
      crystal_graph = ParityTargetSymbolSpecHelpers.extract_fixture_graph(dir, ["src/prolog_input.cr"], cache_dir)
      Chiasmus::Graph::GraphCache.flush_async_writes

      source_facts_path = File.join(dir, "source.pl")
      crystal_facts_path = File.join(dir, "crystal.pl")
      ParityTargetSymbolSpecHelpers.write_facts(source_facts_path, source_graph)
      ParityTargetSymbolSpecHelpers.write_facts(crystal_facts_path, crystal_graph)

      result = Chiasmus::Parity.analyze(
        inventory_path: File.join(dir, "plans", "inventory", "port.tsv"),
        root_dir: dir,
        crystal_dirs: ["src"],
        parser_mode: "tree-sitter",
        source_facts_path: source_facts_path,
        crystal_facts_path: crystal_facts_path,
      )

      row = result.rows.first
      row.match_status.should eq("curated_alias")
      row.crystal_name.should eq("extract_prolog_query")
      row.basis.should eq("target_symbol")
      row.structural_status.should eq("structural_match"), row.structural_details
    ensure
      Chiasmus::Graph::GraphCache.flush_async_writes
      Chiasmus::Graph::GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(dir)
    end
  end

  it "uses target_symbol to map a renamed method deterministically" do
    dir = ParityTargetSymbolSpecHelpers.parity_fixture_repo("renamed-method")
    cache_dir = File.join(dir, "cache")
    begin
      ParityTargetSymbolSpecHelpers.copy_fixture(dir, "typescript/solver-session.ts", "src/solvers/session.ts")
      ParityTargetSymbolSpecHelpers.copy_fixture(dir, "crystal/solver_session_renamed.cr", "src/solver_session.cr")
      Dir.mkdir_p(File.join(dir, "plans", "inventory"))

      File.write(File.join(dir, "plans", "inventory", "port.tsv"), <<-TSV)
# source_id	kind	status	crystal_refs	target_symbol	test_refs	notes
src/solvers/session.ts::method::solve	method	ported	src/solver_session.cr:40	run	-	Ported as run
TSV

      source_graph = ParityTargetSymbolSpecHelpers.extract_fixture_graph(dir, ["src/solvers/session.ts"], cache_dir)
      crystal_graph = ParityTargetSymbolSpecHelpers.extract_fixture_graph(dir, ["src/solver_session.cr"], cache_dir)
      Chiasmus::Graph::GraphCache.flush_async_writes

      source_facts_path = File.join(dir, "source.pl")
      crystal_facts_path = File.join(dir, "crystal.pl")
      ParityTargetSymbolSpecHelpers.write_facts(source_facts_path, source_graph)
      ParityTargetSymbolSpecHelpers.write_facts(crystal_facts_path, crystal_graph)

      result = Chiasmus::Parity.analyze(
        inventory_path: File.join(dir, "plans", "inventory", "port.tsv"),
        root_dir: dir,
        crystal_dirs: ["src"],
        parser_mode: "tree-sitter",
        source_facts_path: source_facts_path,
        crystal_facts_path: crystal_facts_path,
      )

      row = result.rows.first
      row.match_status.should eq("curated_alias")
      row.crystal_name.should eq("SolverSession.run")
      row.basis.should eq("target_symbol")
      row.structural_status.should eq("structural_match")
    ensure
      Chiasmus::Graph::GraphCache.flush_async_writes
      Chiasmus::Graph::GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(dir)
    end
  end

  it "surfaces method divergence at the class level for a vendor-derived fixture" do
    dir = ParityTargetSymbolSpecHelpers.parity_fixture_repo("class-drift")
    cache_dir = File.join(dir, "cache")
    begin
      ParityTargetSymbolSpecHelpers.copy_fixture(dir, "typescript/solver-session.ts", "src/solvers/session.ts")
      ParityTargetSymbolSpecHelpers.copy_fixture(dir, "crystal/solver_session_renamed.cr", "src/solver_session.cr")
      Dir.mkdir_p(File.join(dir, "plans", "inventory"))

      File.write(File.join(dir, "plans", "inventory", "port.tsv"), <<-TSV)
# source_id	kind	status	crystal_refs	target_symbol	test_refs	notes
src/solvers/session.ts::class::SolverSession	class	ported	src/solver_session.cr:1	SolverSession	-	Ported with renamed solve method
TSV

      source_graph = ParityTargetSymbolSpecHelpers.extract_fixture_graph(dir, ["src/solvers/session.ts"], cache_dir)
      crystal_graph = ParityTargetSymbolSpecHelpers.extract_fixture_graph(dir, ["src/solver_session.cr"], cache_dir)
      Chiasmus::Graph::GraphCache.flush_async_writes

      source_facts_path = File.join(dir, "source.pl")
      crystal_facts_path = File.join(dir, "crystal.pl")
      ParityTargetSymbolSpecHelpers.write_facts(source_facts_path, source_graph)
      ParityTargetSymbolSpecHelpers.write_facts(crystal_facts_path, crystal_graph)

      result = Chiasmus::Parity.analyze(
        inventory_path: File.join(dir, "plans", "inventory", "port.tsv"),
        root_dir: dir,
        crystal_dirs: ["src"],
        parser_mode: "tree-sitter",
        source_facts_path: source_facts_path,
        crystal_facts_path: crystal_facts_path,
      )

      row = result.rows.first
      row.crystal_name.should eq("SolverSession")
      row.structural_status.should eq("structural_drift")
      row.structural_details.should contain("missing_contains=solve")
      row.structural_details.should contain("extra_contains=run")
    ensure
      Chiasmus::Graph::GraphCache.flush_async_writes
      Chiasmus::Graph::GraphCache.close_file_cache_stores_for_test
      FileUtils.rm_rf(dir)
    end
  end
end
