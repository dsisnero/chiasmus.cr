require "../spec_helper"
require "file_utils"

describe "check_completion_gate.sh" do
  it "wires fact extraction into the completion gate wrapper" do
    dir = File.join(Dir.tempdir, "chiasmus-completion-script-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(File.join(dir, "src"))
    Dir.mkdir_p(File.join(dir, "vendor", "source"))
    Dir.mkdir_p(File.join(dir, "plans", "inventory"))
    Dir.mkdir_p(File.join(dir, "bin"))

    begin
      inventory_path = File.join(dir, "plans", "inventory", "port.tsv")
      File.write(inventory_path, <<-TSV)
# source_id	kind	status	crystal_refs	notes
src/app.ts::function::main	function	ported	src/main.cr:1,spec/main_spec.cr:1	Covered
TSV

      log_path = File.join(dir, "tool.log")
      facts_bin = File.join(dir, "bin", "fake-facts")
      complete_bin = File.join(dir, "bin", "fake-complete")

      File.write(facts_bin, <<-SH)
#!/usr/bin/env bash
set -euo pipefail
printf 'facts:%s\n' "$*" >> #{log_path.inspect}
printf "%% facts\\nentry_point('main').\\n"
SH
      File.write(complete_bin, <<-SH)
#!/usr/bin/env bash
set -euo pipefail
printf 'complete:%s\n' "$*" >> #{log_path.inspect}
printf "status\tincomplete\nincomplete_count\t1\n"
exit 2
SH
      File.chmod(facts_bin, 0o755_i32)
      File.chmod(complete_bin, 0o755_i32)

      script = File.expand_path("../../scripts/check_completion_gate.sh", __DIR__)

      output_io = IO::Memory.new
      error_io = IO::Memory.new
      status = Process.run(
        "bash",
        [script, dir, inventory_path, "vendor/source", "typescript", "src"],
        output: output_io,
        error: error_io,
        env: {
          "CHIASMUS_FACTS_BIN"    => facts_bin,
          "CHIASMUS_COMPLETE_BIN" => complete_bin,
          "PORT_CRYSTAL_DIRS"     => "src:spec",
          "PORT_ENTRY_POINTS"     => "main,cli",
          "PORT_PARSER"           => "regex",
        }
      )

      status.exit_code.should eq(2), error_io.to_s

      log = File.read(log_path)
      log.should contain("facts:--language typescript --dir #{dir}/vendor/source --entry-point main --entry-point cli")
      log.should contain("facts:--language crystal --dir #{dir}/src --entry-point main --entry-point cli")
      log.should contain("complete:--inventory #{inventory_path} --root #{dir}")
      log.should contain("--parser regex")
      log.should contain("--crystal-dir src --crystal-dir spec")
      log.should match(/--source-facts \S*chiasmus-complete\.[^\s]*\/source\.pl/)
      log.should match(/--crystal-facts \S*chiasmus-complete\.[^\s]*\/crystal\.pl/)
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
