require "../spec_helper"
require "file_utils"

private def plan_facts_meta(language : String, dir : String, entry_points : String = "") : String
  <<-TEXT
language=#{language}
dir=#{dir}
entry_points=#{entry_points}
TEXT
end

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
      log.should contain("complete:--inventory #{inventory_path} --source-facts #{out_dir}/source_facts.pl --parity-report #{out_dir}/parity.tsv --query status")
      log.should contain("complete:--inventory #{inventory_path} --source-facts #{out_dir}/source_facts.pl --parity-report #{out_dir}/parity.tsv --query incomplete --format tsv")
    ensure
      FileUtils.rm_rf(dir)
      FileUtils.rm_rf(shared_vendor_dir)
    end
  end

  it "reuses fresh plan_with_chiasmus facts snapshots when metadata matches" do
    dir = File.join(Dir.tempdir, "chiasmus-plan-cache-#{Random::Secure.hex(8)}")
    shared_vendor_dir = File.join(Dir.tempdir, "chiasmus-plan-cache-shared-vendor-#{Random::Secure.hex(8)}")
    source_dir = File.join(shared_vendor_dir, "source")
    crystal_dir = File.join(dir, "src")
    out_dir = File.join(dir, "plans", "generated")
    Dir.mkdir_p(source_dir)
    Dir.mkdir_p(crystal_dir)
    Dir.mkdir_p(File.join(dir, "plans", "inventory"))
    Dir.mkdir_p(File.join(dir, "bin"))

    begin
      File.write(File.join(source_dir, "app.ts"), "export function main() {}\n")
      File.write(File.join(crystal_dir, "app.cr"), "def main; end\n")

      inventory_path = File.join(dir, "plans", "inventory", "typescript_port_inventory.tsv")
      File.write(inventory_path, <<-TSV)
# source_id	kind	status	crystal_refs	notes
src/app.ts::function::main	function	ported	src/main.cr:1,spec/main_spec.cr:1	Covered
TSV

      Dir.mkdir_p(out_dir)
      source_facts_path = File.join(out_dir, "source_facts.pl")
      crystal_facts_path = File.join(out_dir, "crystal_facts.pl")
      File.write(source_facts_path, "cached source facts\n")
      File.write(crystal_facts_path, "cached crystal facts\n")
      File.write("#{source_facts_path}.meta", plan_facts_meta("typescript", source_dir, "main,cli"))
      File.write("#{crystal_facts_path}.meta", plan_facts_meta("crystal", crystal_dir, "main,cli"))

      log_path = File.join(dir, "tool.log")
      facts_bin = File.join(dir, "bin", "fake-facts")
      plan_bin = File.join(dir, "bin", "fake-plan")
      parity_bin = File.join(dir, "bin", "fake-parity")
      complete_bin = File.join(dir, "bin", "fake-complete")
      ruby_bin = File.join(dir, "bin", "ruby")

      File.write(facts_bin, <<-SH)
#!/usr/bin/env bash
set -euo pipefail
printf 'facts:%s\n' "$*" >> #{log_path.inspect}
printf "generated:%s\\n" "$*"
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
          "PORT_ENTRY_POINTS"     => "main,cli",
          "PORT_PARSER"           => "regex",
          "PORT_CRYSTAL_DIRS"     => "src:spec",
          "VENDOR_DIR"            => shared_vendor_dir,
        }
      )

      status.success?.should be_true, error_io.to_s

      log = File.read(log_path)
      log.should_not contain("facts:")
      log.should contain("plan:rank --facts #{source_facts_path} --format tsv --top 25 --entry-point main --entry-point cli")
      File.read(source_facts_path).should eq("cached source facts\n")
      File.read(crystal_facts_path).should eq("cached crystal facts\n")
    ensure
      FileUtils.rm_rf(dir)
      FileUtils.rm_rf(shared_vendor_dir)
    end
  end

  it "refreshes stale source facts without rerunning fresh crystal facts" do
    dir = File.join(Dir.tempdir, "chiasmus-plan-refresh-#{Random::Secure.hex(8)}")
    shared_vendor_dir = File.join(Dir.tempdir, "chiasmus-plan-refresh-shared-vendor-#{Random::Secure.hex(8)}")
    source_dir = File.join(shared_vendor_dir, "source")
    crystal_dir = File.join(dir, "src")
    out_dir = File.join(dir, "plans", "generated")
    Dir.mkdir_p(source_dir)
    Dir.mkdir_p(crystal_dir)
    Dir.mkdir_p(File.join(dir, "plans", "inventory"))
    Dir.mkdir_p(File.join(dir, "bin"))

    begin
      source_file = File.join(source_dir, "app.ts")
      crystal_file = File.join(crystal_dir, "app.cr")
      File.write(source_file, "export function main() {}\n")
      File.write(crystal_file, "def main; end\n")

      inventory_path = File.join(dir, "plans", "inventory", "typescript_port_inventory.tsv")
      File.write(inventory_path, <<-TSV)
# source_id	kind	status	crystal_refs	notes
src/app.ts::function::main	function	ported	src/main.cr:1,spec/main_spec.cr:1	Covered
TSV

      Dir.mkdir_p(out_dir)
      source_facts_path = File.join(out_dir, "source_facts.pl")
      crystal_facts_path = File.join(out_dir, "crystal_facts.pl")
      File.write(source_facts_path, "stale source facts\n")
      File.write(crystal_facts_path, "fresh crystal facts\n")
      File.write("#{source_facts_path}.meta", plan_facts_meta("typescript", source_dir))
      File.write("#{crystal_facts_path}.meta", plan_facts_meta("crystal", crystal_dir))

      sleep 1100.milliseconds
      File.write(source_file, "export function main() { return 1; }\n")

      log_path = File.join(dir, "tool.log")
      facts_bin = File.join(dir, "bin", "fake-facts")
      plan_bin = File.join(dir, "bin", "fake-plan")
      parity_bin = File.join(dir, "bin", "fake-parity")
      complete_bin = File.join(dir, "bin", "fake-complete")
      ruby_bin = File.join(dir, "bin", "ruby")

      File.write(facts_bin, <<-SH)
#!/usr/bin/env bash
set -euo pipefail
printf 'facts:%s\n' "$*" >> #{log_path.inspect}
printf "generated:%s\\n" "$*"
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
      log.lines.count(&.starts_with?("facts:")).should eq(1)
      log.should contain("facts:--language typescript --dir #{source_dir}")
      log.should_not contain("facts:--language crystal --dir #{crystal_dir}")
      File.read(source_facts_path).should contain("generated:--language typescript --dir #{source_dir}")
      File.read(crystal_facts_path).should eq("fresh crystal facts\n")
    ensure
      FileUtils.rm_rf(dir)
      FileUtils.rm_rf(shared_vendor_dir)
    end
  end

  it "runs independent planner and completion subcommands in parallel" do
    dir = File.join(Dir.tempdir, "chiasmus-plan-parallel-#{Random::Secure.hex(8)}")
    shared_vendor_dir = File.join(Dir.tempdir, "chiasmus-plan-parallel-shared-vendor-#{Random::Secure.hex(8)}")
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
printf "%% facts\\n"
SH
      File.write(plan_bin, <<-SH)
#!/usr/bin/env bash
set -euo pipefail
mode="$1"
printf 'plan-start:%s\n' "${mode}" >> #{log_path.inspect}
sleep 1
printf 'plan-end:%s\n' "${mode}" >> #{log_path.inspect}
printf "slice_id\tslice_kind\n"
SH
      File.write(parity_bin, <<-SH)
#!/usr/bin/env bash
set -euo pipefail
printf "source_id\tstatus\n"
SH
      File.write(complete_bin, <<-SH)
#!/usr/bin/env bash
set -euo pipefail
query="status"
while (($#)); do
  if [[ "$1" == "--query" ]]; then
    query="$2"
    shift 2
    continue
  fi
  shift
done
printf 'complete-start:%s\n' "${query}" >> #{log_path.inspect}
sleep 1
printf 'complete-end:%s\n' "${query}" >> #{log_path.inspect}
printf "status\tcomplete\n"
SH
      File.write(ruby_bin, <<-SH)
#!/usr/bin/env bash
set -euo pipefail
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

      log_lines = File.read(log_path).lines.map(&.strip)
      first_plan_end = log_lines.index(&.starts_with?("plan-end:")) || raise "missing plan end marker"
      log_lines[0, first_plan_end].count(&.starts_with?("plan-start:")).should eq(5)

      first_complete_end = log_lines.index(&.starts_with?("complete-end:")) || raise "missing complete end marker"
      complete_window = log_lines.select { |line| line.starts_with?("complete-start:") || line.starts_with?("complete-end:") }
      complete_first_end = complete_window.index(&.starts_with?("complete-end:")) || raise "missing complete window end marker"
      first_complete_end.should be >= 0
      complete_window[0, complete_first_end].count(&.starts_with?("complete-start:")).should eq(2)
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
