require "spec"
require "file_utils"
require "../../src/chiasmus/complete"
require "../../src/chiasmus/graph/community"
require "../../src/chiasmus/graph/facts"
require "../../src/chiasmus/graph/insights"
require "../../src/chiasmus/graph/types"

private def build_completion_gate_fixture(mark_needs_test_complete : Bool = false) : String
  dir = File.join(Dir.tempdir, "chiasmus-complete-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(File.join(dir, "src"))
  Dir.mkdir_p(File.join(dir, "spec"))
  Dir.mkdir_p(File.join(dir, "plans", "inventory"))

  File.write(File.join(dir, "src", "port.cr"), <<-CR)
def main
  complete_me
  needs_test
end

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

  needs_test_refs = mark_needs_test_complete ? "src/port.cr:8,spec/needs_test_spec.cr:1" : "src/port.cr:8"
  if mark_needs_test_complete
    File.write(File.join(dir, "spec", "needs_test_spec.cr"), <<-CR)
describe "needs_test" do
  it "is covered" do
    true.should be_true
  end
end
CR
  end

  inventory_path = File.join(dir, "plans", "inventory", "port.tsv")
  File.write(inventory_path, <<-TSV)
# source_id	kind	status	crystal_refs	notes
src/app.ts::function::completeMe	function	ported	src/port.cr:5,spec/complete_me_spec.cr:1	Covered by spec ref
src/app.ts::function::needsTest	function	ported	#{needs_test_refs}	#{mark_needs_test_complete ? "Covered by spec ref" : "Missing explicit spec ref"}
src/app.ts::function::deadHelper	function	missing	-	Unreachable helper
TSV

  source_graph = Chiasmus::Graph::CodeGraph.new(
    defines: [
      Chiasmus::Graph::DefinesFact.new(file: "src/app.ts", name: "main", kind: Chiasmus::Graph::SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1, 1)),
      Chiasmus::Graph::DefinesFact.new(file: "src/app.ts", name: "completeMe", kind: Chiasmus::Graph::SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(2, 2)),
      Chiasmus::Graph::DefinesFact.new(file: "src/app.ts", name: "needsTest", kind: Chiasmus::Graph::SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(3, 3)),
      Chiasmus::Graph::DefinesFact.new(file: "src/app.ts", name: "deadHelper", kind: Chiasmus::Graph::SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(4, 4)),
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
      Chiasmus::Graph::DefinesFact.new(file: "src/port.cr", name: "main", kind: Chiasmus::Graph::SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1, 1)),
      Chiasmus::Graph::DefinesFact.new(file: "src/port.cr", name: "complete_me", kind: Chiasmus::Graph::SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(5, 5)),
      Chiasmus::Graph::DefinesFact.new(file: "src/port.cr", name: "needs_test", kind: Chiasmus::Graph::SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(8, 8)),
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
  dir
end

describe Chiasmus::Complete::CLI do
  it "returns a failing status when reachable work remains incomplete" do
    dir = build_completion_gate_fixture

    begin
      output = IO::Memory.new
      error = IO::Memory.new
      exit_code = Chiasmus::Complete::CLI.run(
        [
          "--inventory", File.join(dir, "plans", "inventory", "port.tsv"),
          "--root", dir,
          "--crystal-dir", "src",
          "--source-facts", File.join(dir, "source.pl"),
          "--crystal-facts", File.join(dir, "crystal.pl"),
        ],
        output,
        error
      )

      exit_code.should eq(2), error.to_s
      output.to_s.should contain("status\tincomplete")
      output.to_s.should contain("incomplete_count\t1")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "lists incomplete ids without failing the command" do
    dir = build_completion_gate_fixture

    begin
      output = IO::Memory.new
      error = IO::Memory.new
      exit_code = Chiasmus::Complete::CLI.run(
        [
          "--inventory", File.join(dir, "plans", "inventory", "port.tsv"),
          "--root", dir,
          "--crystal-dir", "src",
          "--source-facts", File.join(dir, "source.pl"),
          "--crystal-facts", File.join(dir, "crystal.pl"),
          "--query", "incomplete",
          "--format", "ids",
        ],
        output,
        error
      )

      exit_code.should eq(0), error.to_s
      output.to_s.should eq("src/app.ts::function::needsTest\n")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "returns a passing status when no reachable incomplete work remains" do
    dir = build_completion_gate_fixture(mark_needs_test_complete: true)

    begin
      output = IO::Memory.new
      error = IO::Memory.new
      exit_code = Chiasmus::Complete::CLI.run(
        [
          "--inventory", File.join(dir, "plans", "inventory", "port.tsv"),
          "--root", dir,
          "--crystal-dir", "src",
          "--source-facts", File.join(dir, "source.pl"),
          "--crystal-facts", File.join(dir, "crystal.pl"),
        ],
        output,
        error
      )

      exit_code.should eq(0), error.to_s
      output.to_s.should contain("status\tcomplete")
      output.to_s.should contain("incomplete_count\t0")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "reuses a precomputed parity report instead of requiring crystal facts" do
    dir = build_completion_gate_fixture(mark_needs_test_complete: true)

    begin
      parity_output = IO::Memory.new
      parity_error = IO::Memory.new
      parity_exit_code = Chiasmus::Parity::CLI.run(
        [
          "--inventory", File.join(dir, "plans", "inventory", "port.tsv"),
          "--root", dir,
          "--crystal-dir", "src",
          "--source-facts", File.join(dir, "source.pl"),
          "--crystal-facts", File.join(dir, "crystal.pl"),
        ],
        parity_output,
        parity_error
      )

      parity_exit_code.should eq(0), parity_error.to_s

      parity_report_path = File.join(dir, "parity.tsv")
      File.write(parity_report_path, parity_output.to_s)

      output = IO::Memory.new
      error = IO::Memory.new
      exit_code = Chiasmus::Complete::CLI.run(
        [
          "--inventory", File.join(dir, "plans", "inventory", "port.tsv"),
          "--source-facts", File.join(dir, "source.pl"),
          "--parity-report", parity_report_path,
        ],
        output,
        error
      )

      exit_code.should eq(0), error.to_s
      output.to_s.should contain("status\tcomplete")
      output.to_s.should contain("incomplete_count\t0")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "treats explicit test_refs as coverage in header-driven ledgers" do
    dir = File.join(Dir.tempdir, "chiasmus-complete-header-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(File.join(dir, "src"))
    Dir.mkdir_p(File.join(dir, "spec"))
    Dir.mkdir_p(File.join(dir, "plans", "inventory"))

    begin
      File.write(File.join(dir, "src", "port.cr"), <<-CR)
def main
  load_config
end

def load_config
end
CR

      File.write(File.join(dir, "spec", "config_spec.cr"), <<-CR)
describe "load_config" do
  it "is covered" do
    true.should be_true
  end
end
CR

      File.write(File.join(dir, "plans", "inventory", "port.tsv"), <<-TSV)
# source_id	kind	status	crystal_refs	target_symbol	test_refs	notes
src/app.ts::function::loadConfig	function	ported	src/port.cr:5	load_config	spec/config_spec.cr:1	Covered by explicit test refs
TSV

      source_graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(file: "src/app.ts", name: "main", kind: Chiasmus::Graph::SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1, 1)),
          Chiasmus::Graph::DefinesFact.new(file: "src/app.ts", name: "loadConfig", kind: Chiasmus::Graph::SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(2, 2)),
        ],
        calls: [
          Chiasmus::Graph::CallsFact.new(caller: "main", callee: "loadConfig"),
        ],
        imports: [] of Chiasmus::Graph::ImportsFact,
        exports: [] of Chiasmus::Graph::ExportsFact,
        contains: [] of Chiasmus::Graph::ContainsFact,
      )

      crystal_graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(file: "src/port.cr", name: "main", kind: Chiasmus::Graph::SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1, 1)),
          Chiasmus::Graph::DefinesFact.new(file: "src/port.cr", name: "load_config", kind: Chiasmus::Graph::SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(5, 5)),
        ],
        calls: [
          Chiasmus::Graph::CallsFact.new(caller: "main", callee: "load_config"),
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
      exit_code = Chiasmus::Complete::CLI.run(
        [
          "--inventory", File.join(dir, "plans", "inventory", "port.tsv"),
          "--root", dir,
          "--crystal-dir", "src",
          "--source-facts", source_facts_path,
          "--crystal-facts", crystal_facts_path,
        ],
        output,
        error
      )

      exit_code.should eq(0), error.to_s
      output.to_s.should contain("status\tcomplete")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "does not mark duplicate-name source rows reachable outside scoped entry-point flow" do
    dir = File.join(Dir.tempdir, "chiasmus-complete-scoped-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(File.join(dir, "src"))
    Dir.mkdir_p(File.join(dir, "spec"))
    Dir.mkdir_p(File.join(dir, "plans", "inventory"))

    begin
      File.write(File.join(dir, "src", "port.cr"), <<-CR)
def main
  helper
end

def helper
  leaf
end

def leaf
end
CR

      File.write(File.join(dir, "spec", "leaf_spec.cr"), <<-CR)
describe "leaf" do
  it "is covered" do
    true.should be_true
  end
end
CR

      File.write(File.join(dir, "plans", "inventory", "port.tsv"), <<-TSV)
# source_id	kind	status	crystal_refs	notes
src/app.ts::function::leaf	function	ported	src/port.cr:9,spec/leaf_spec.cr:1	Covered reachable leaf
src/util.ts::function::leaf	function	missing	-	Unreachable duplicate leaf
TSV

      source_graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(file: "src/app.ts", name: "main", kind: Chiasmus::Graph::SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1, 1)),
          Chiasmus::Graph::DefinesFact.new(file: "src/app.ts", name: "helper", kind: Chiasmus::Graph::SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(5, 5)),
          Chiasmus::Graph::DefinesFact.new(file: "src/app.ts", name: "leaf", kind: Chiasmus::Graph::SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(9, 9)),
          Chiasmus::Graph::DefinesFact.new(file: "src/util.ts", name: "helper", kind: Chiasmus::Graph::SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(3, 3)),
          Chiasmus::Graph::DefinesFact.new(file: "src/util.ts", name: "leaf", kind: Chiasmus::Graph::SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(7, 7)),
        ],
        calls: [
          Chiasmus::Graph::CallsFact.new(caller: "main", callee: "helper"),
          Chiasmus::Graph::CallsFact.new(caller: "helper", callee: "leaf"),
        ],
        imports: [] of Chiasmus::Graph::ImportsFact,
        exports: [] of Chiasmus::Graph::ExportsFact,
        contains: [] of Chiasmus::Graph::ContainsFact,
      )

      crystal_graph = Chiasmus::Graph::CodeGraph.new(
        defines: [
          Chiasmus::Graph::DefinesFact.new(file: "src/port.cr", name: "main", kind: Chiasmus::Graph::SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1, 1)),
          Chiasmus::Graph::DefinesFact.new(file: "src/port.cr", name: "helper", kind: Chiasmus::Graph::SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(5, 5)),
          Chiasmus::Graph::DefinesFact.new(file: "src/port.cr", name: "leaf", kind: Chiasmus::Graph::SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(9, 9)),
        ],
        calls: [
          Chiasmus::Graph::CallsFact.new(caller: "main", callee: "helper"),
          Chiasmus::Graph::CallsFact.new(caller: "helper", callee: "leaf"),
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
      exit_code = Chiasmus::Complete::CLI.run(
        [
          "--inventory", File.join(dir, "plans", "inventory", "port.tsv"),
          "--root", dir,
          "--crystal-dir", "src",
          "--source-facts", source_facts_path,
          "--crystal-facts", crystal_facts_path,
        ],
        output,
        error
      )

      exit_code.should eq(0), error.to_s
      output.to_s.should contain("status\tcomplete")
      output.to_s.should contain("incomplete_count\t0")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
