require "../spec_helper"
require "file_utils"

describe "verify_parity_adversarial.sh" do
  it "runs the completion gate wrapper as part of parity signoff" do
    dir = File.join(Dir.tempdir, "chiasmus-verify-parity-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(File.join(dir, "vendor", "source"))
    Dir.mkdir_p(File.join(dir, "plans", "inventory"))
    Dir.mkdir_p(File.join(dir, "helpers"))

    begin
      inventory_path = File.join(dir, "plans", "inventory", "typescript_port_inventory.tsv")
      source_manifest = File.join(dir, "plans", "inventory", "typescript_source_parity.tsv")
      test_manifest = File.join(dir, "plans", "inventory", "typescript_test_parity.tsv")

      File.write(inventory_path, <<-TSV)
# source_id	kind	status	crystal_refs	notes
src/app.ts::function::main	function	ported	src/main.cr:1,spec/main_spec.cr:1	Covered
TSV
      File.write(source_manifest, <<-TSV)
# source_id	status	crystal_refs	notes
src/app.ts::function::main	ported	src/main.cr:1	Covered
TSV
      File.write(test_manifest, <<-TSV)
# source_id	status	crystal_refs	notes
src/app.ts::function::main	ported	spec/main_spec.cr:1	Covered
TSV

      log_path = File.join(dir, "helpers", "log.txt")
      ensure_script = File.join(dir, "helpers", "ensure.sh")
      complete_script = File.join(dir, "helpers", "complete.sh")

      File.write(ensure_script, <<-SH)
#!/usr/bin/env bash
set -euo pipefail
printf 'ensure:%s\n' "$*" >> #{log_path.inspect}
SH
      File.write(complete_script, <<-SH)
#!/usr/bin/env bash
set -euo pipefail
printf 'complete:%s\n' "$*" >> #{log_path.inspect}
printf "status\tcomplete\nincomplete_count\t0\n"
SH
      File.chmod(ensure_script, 0o755_i32)
      File.chmod(complete_script, 0o755_i32)

      script = File.expand_path("../../scripts/verify_parity_adversarial.sh", __DIR__)

      output_io = IO::Memory.new
      error_io = IO::Memory.new
      status = Process.run(
        "bash",
        [script, dir, "vendor/source", "typescript"],
        output: output_io,
        error: error_io,
        env: {
          "ENSURE_PARITY_PLAN_SCRIPT"    => ensure_script,
          "CHECK_COMPLETION_GATE_SCRIPT" => complete_script,
          "PORT_PARSER"                  => "regex",
        }
      )

      status.success?.should be_true, error_io.to_s
      output_io.to_s.should contain("Adversarial parity verification passed for language=typescript.")

      log = File.read(log_path)
      log.should contain("ensure:#{dir} vendor/source typescript regex 0")
      log.should contain("complete:#{dir} #{inventory_path} vendor/source typescript")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
