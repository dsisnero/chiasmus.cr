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
      Chiasmus::Graph::DefinesFact.new(file: "src/port.cr", name: "complete_me", kind: Chiasmus::Graph::SymbolKind::Function, line: 5, end_line: 5),
      Chiasmus::Graph::DefinesFact.new(file: "src/port.cr", name: "needs_test", kind: Chiasmus::Graph::SymbolKind::Function, line: 8, end_line: 8),
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
end
