require "../spec_helper"
require "file_utils"

describe "shared vendor path script integration" do
  it "lets plan_with_chiasmus.sh resolve vendor paths through VENDOR_DIR" do
    dir = File.join(Dir.tempdir, "chiasmus-plan-script-#{Random::Secure.hex(8)}")
    shared_vendor_dir = File.join(Dir.tempdir, "chiasmus-plan-shared-vendor-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(File.join(dir, "src"))
    Dir.mkdir_p(File.join(dir, "plans", "inventory"))
    Dir.mkdir_p(File.join(dir, "bin"))
    Dir.mkdir_p(File.join(shared_vendor_dir, "source"))

    begin
      inventory_path = File.join(dir, "plans", "inventory", "typescript_port_inventory.tsv")
      File.write(inventory_path, <<-TSV)
# source_id	kind	status	crystal_refs	notes
src/app.ts::function::main	function	ported	src/main.cr:1,spec/main_spec.cr:1	Covered
TSV

      log_path = File.join(dir, "tool.log")
      facts_bin = File.join(dir, "bin", "fake-facts")
      plan_bin = File.join(dir, "bin", "fake-plan")
      parity_bin = File.join(dir, "bin", "fake-parity")
      complete_bin = File.join(dir, "bin", "fake-complete")
      ruby_bin = File.join(dir, "bin", "ruby")
      out_dir = File.join(dir, "plans", "generated")

      File.write(facts_bin, <<-SH)
#!/usr/bin/env bash
set -euo pipefail
printf 'facts:%s\n' "$*" >> #{log_path.inspect}
printf "%% facts\\n"
SH
      File.write(plan_bin, <<-SH)
#!/usr/bin/env bash
set -euo pipefail
printf 'plan:%s\n' "$*" >> #{log_path.inspect}
printf "slice_id\tslice_kind\n"
SH
      File.write(parity_bin, <<-SH)
#!/usr/bin/env bash
set -euo pipefail
printf 'parity:%s\n' "$*" >> #{log_path.inspect}
printf "source_id\tstatus\n"
SH
      File.write(complete_bin, <<-SH)
#!/usr/bin/env bash
set -euo pipefail
printf 'complete:%s\n' "$*" >> #{log_path.inspect}
printf "status\tcomplete\n"
SH
      File.write(ruby_bin, <<-SH)
#!/usr/bin/env bash
set -euo pipefail
printf 'ruby:%s\n' "$*" >> #{log_path.inspect}
printf "summary\n"
SH

      {facts_bin, plan_bin, parity_bin, complete_bin, ruby_bin}.each do |path|
        File.chmod(path, 0o755_i32)
      end

      script = File.expand_path("../../scripts/plan_with_chiasmus.sh", __DIR__)
      output_io = IO::Memory.new
      error_io = IO::Memory.new
      status = Process.run(
        "bash",
        [script, dir, "vendor/source", "typescript", "src", out_dir],
        output: output_io,
        error: error_io,
        env: {
          "CHIASMUS_FACTS_BIN"    => facts_bin,
          "CHIASMUS_PLAN_BIN"     => plan_bin,
          "CHIASMUS_PARITY_BIN"   => parity_bin,
          "CHIASMUS_COMPLETE_BIN" => complete_bin,
          "PATH"                  => "#{File.join(dir, "bin")}:#{ENV["PATH"]? || ""}",
          "PORT_PARSER"           => "regex",
          "PORT_CRYSTAL_DIRS"     => "src:spec",
          "VENDOR_DIR"            => shared_vendor_dir,
        }
      )

      status.success?.should be_true, error_io.to_s

      log = File.read(log_path)
      log.should contain("facts:--language typescript --dir #{shared_vendor_dir}/source")
      log.should contain("facts:--language crystal --dir #{dir}/src")
      log.should contain("plan:rank --facts #{out_dir}/source_facts.pl --format tsv --top 25")
      log.should contain("parity:--inventory #{inventory_path} --root #{dir}")
      log.should contain("complete:--inventory #{inventory_path} --root #{dir}")
    ensure
      FileUtils.rm_rf(dir)
      FileUtils.rm_rf(shared_vendor_dir)
    end
  end

  it "lets generate_typescript_inventory.sh resolve vendor paths through VENDOR_DIR" do
    dir = File.join(Dir.tempdir, "chiasmus-generate-ts-#{Random::Secure.hex(8)}")
    shared_vendor_dir = File.join(Dir.tempdir, "chiasmus-generate-ts-shared-vendor-#{Random::Secure.hex(8)}")
    source_root = File.join(shared_vendor_dir, "chiasmus")
    output_dir = File.join(dir, "plans", "inventory")

    Dir.mkdir_p(source_root)
    Dir.mkdir_p(output_dir)

    begin
      File.write(File.join(source_root, "alpha.ts"), <<-TS)
export function alpha() {}
TS

      script = File.expand_path("../../scripts/generate_typescript_inventory.sh", __DIR__)
      output_io = IO::Memory.new
      error_io = IO::Memory.new
      status = Process.run(
        "bash",
        [script, dir, "vendor/chiasmus", output_dir],
        output: output_io,
        error: error_io,
        env: {
          "VENDOR_DIR" => shared_vendor_dir,
        }
      )

      status.success?.should be_true, error_io.to_s

      port_inventory = File.read(File.join(output_dir, "typescript_port_inventory.tsv"))
      source_parity = File.read(File.join(output_dir, "typescript_source_parity.tsv"))

      port_inventory.should contain("alpha.ts::function::alpha\tfunction\tmissing\t-\t")
      source_parity.should contain("alpha.ts::function::alpha\tmissing\t-\t")
    ensure
      FileUtils.rm_rf(dir)
      FileUtils.rm_rf(shared_vendor_dir)
    end
  end
end
