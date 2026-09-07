require "spec"
require "file_utils"
require "../spec_helper"
require "../support/complete_fixture"

private def build_completion_process_fixture : String
  dir = File.join(Dir.tempdir, "chiasmus-complete-process-#{Random::Secure.hex(8)}")
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

  inventory_path = File.join(dir, "plans", "inventory", "port.tsv")
  File.write(inventory_path, <<-TSV)
# source_id	kind	status	crystal_refs	notes
src/app.ts::function::completeMe	function	ported	src/port.cr:5,spec/complete_me_spec.cr:1	Covered by spec ref
src/app.ts::function::needsTest	function	ported	src/port.cr:8	Missing explicit spec ref
TSV

  source_graph = Chiasmus::Graph::CodeGraph.new(
    defines: [
      Chiasmus::Graph::DefinesFact.new(file: "src/app.ts", name: "main", kind: Chiasmus::Graph::SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(1, 1)),
      Chiasmus::Graph::DefinesFact.new(file: "src/app.ts", name: "completeMe", kind: Chiasmus::Graph::SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(2, 2)),
      Chiasmus::Graph::DefinesFact.new(file: "src/app.ts", name: "needsTest", kind: Chiasmus::Graph::SymbolKind::Function, span: Chiasmus::Graph::Span.line_range(3, 3)),
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

  File.write(File.join(dir, "source.pl"), Chiasmus::Graph::Facts.graph_to_prolog(source_graph, ["main"]))
  File.write(File.join(dir, "crystal.pl"), Chiasmus::Graph::Facts.graph_to_prolog(crystal_graph, ["main"]))
  dir
end

describe "chiasmus-complete CLI process" do
  it "exits after serving an incomplete query" do
    dir = build_completion_process_fixture
    binary = build_chiasmus_complete_cli

    begin
      output_path = File.join(dir, "complete.out")
      error_path = File.join(dir, "complete.err")
      output_io = File.open(output_path, "w")
      error_io = File.open(error_path, "w")

      proc = Process.new(
        binary,
        args: [
          "--inventory", File.join(dir, "plans", "inventory", "port.tsv"),
          "--root", dir,
          "--source-facts", File.join(dir, "source.pl"),
          "--crystal-facts", File.join(dir, "crystal.pl"),
          "--query", "incomplete",
          "--format", "ids",
        ],
        env: chiasmus_cli_env,
        output: output_io,
        error: error_io,
      )

      status_channel = Channel(Process::Status).new(1)
      spawn { status_channel.send(proc.wait) }

      status = nil.as(Process::Status?)
      select
      when result = status_channel.receive
        status = result
      when timeout(10.seconds)
      end

      if status.nil?
        proc.terminate rescue nil
        fail "chiasmus-complete did not exit within 10 seconds"
      end

      output_io.close
      error_io.close
      output = File.read(output_path)
      error = File.read(error_path)

      status.not_nil!.success?.should be_true, error
      output.should eq("src/app.ts::function::needsTest\n")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "lets status and incomplete queries complete concurrently against the cached repo bundle" do
    dir = build_chiasmus_complete_repo_bundle
    binary = build_chiasmus_complete_cli

    status_output_path = File.join(dir, "concurrent-status.out")
    status_error_path = File.join(dir, "concurrent-status.err")
    incomplete_output_path = File.join(dir, "concurrent-incomplete.out")
    incomplete_error_path = File.join(dir, "concurrent-incomplete.err")

    status_output = File.open(status_output_path, "w")
    status_error = File.open(status_error_path, "w")
    incomplete_output = File.open(incomplete_output_path, "w")
    incomplete_error = File.open(incomplete_error_path, "w")

    status_proc = Process.new(
      binary,
      args: [
        "--inventory", File.join(Dir.current, "plans", "inventory", "typescript_port_inventory.tsv"),
        "--root", Dir.current,
        "--source-facts", File.join(dir, "source_facts.pl"),
        "--parity-report", File.join(dir, "parity.tsv"),
        "--query", "status",
      ],
      env: chiasmus_cli_env,
      output: status_output,
      error: status_error,
    )

    incomplete_proc = Process.new(
      binary,
      args: [
        "--inventory", File.join(Dir.current, "plans", "inventory", "typescript_port_inventory.tsv"),
        "--root", Dir.current,
        "--source-facts", File.join(dir, "source_facts.pl"),
        "--parity-report", File.join(dir, "parity.tsv"),
        "--query", "incomplete",
        "--format", "ids",
      ],
      env: chiasmus_cli_env,
      output: incomplete_output,
      error: incomplete_error,
    )

    status_channel = Channel(Process::Status).new(1)
    incomplete_channel = Channel(Process::Status).new(1)
    spawn { status_channel.send(status_proc.wait) }
    spawn { incomplete_channel.send(incomplete_proc.wait) }

    status_result = nil.as(Process::Status?)
    incomplete_result = nil.as(Process::Status?)

    deadline = Time.instant + 20.seconds
    until status_result && incomplete_result
      remaining = deadline - Time.instant
      break if remaining <= Time::Span.zero

      select
      when result = status_channel.receive
        status_result = result
      when result = incomplete_channel.receive
        incomplete_result = result
      when timeout(remaining)
        break
      end
    end

    unless status_result
      status_proc.terminate rescue nil
      fail "status query did not exit within 20 seconds"
    end

    unless incomplete_result
      incomplete_proc.terminate rescue nil
      fail "incomplete query did not exit within 20 seconds"
    end

    status_output.close
    status_error.close
    incomplete_output.close
    incomplete_error.close

    status_stdout = File.read(status_output_path)
    status_stderr = File.read(status_error_path)
    incomplete_stdout = File.read(incomplete_output_path)
    incomplete_stderr = File.read(incomplete_error_path)

    status_result.not_nil!.exit_code.should eq(2), status_stderr
    incomplete_result.not_nil!.success?.should be_true, incomplete_stderr

    expected_status = File.read(File.join(dir, "completion_status.tsv"))
    expected_incomplete_ids = File.read_lines(File.join(dir, "completion_incomplete.tsv"))[1..].map { |line| line.split('\t').first }.sort

    status_stdout.should eq(expected_status)
    incomplete_stdout.lines.sort.should eq(expected_incomplete_ids)
    incomplete_stdout.should contain("src/config.ts::function::loadConfig")
  ensure
    status_output.try(&.close)
    status_error.try(&.close)
    incomplete_output.try(&.close)
    incomplete_error.try(&.close)
  end
end
