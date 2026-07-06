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

  it "works when no entry points are configured" do
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
      facts_bin = File.join(dir, "bin", "chiasmus-facts")
      complete_bin = File.join(dir, "bin", "chiasmus-complete")

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
printf "status\tcomplete\nincomplete_count\t0\n"
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
          "PORT_PARSER"           => "regex",
        }
      )

      status.success?.should be_true, error_io.to_s

      log = File.read(log_path)
      log.should contain("facts:--language typescript --dir #{dir}/vendor/source")
      log.should contain("facts:--language crystal --dir #{dir}/src")
      log.should_not contain("--entry-point")
      log.should contain("complete:--inventory #{inventory_path} --root #{dir}")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "falls back to VENDOR_DIR when the local vendor source path is absent" do
    dir = File.join(Dir.tempdir, "chiasmus-completion-script-#{Random::Secure.hex(8)}")
    shared_vendor_dir = File.join(Dir.tempdir, "chiasmus-shared-vendor-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(File.join(dir, "src"))
    Dir.mkdir_p(File.join(dir, "plans", "inventory"))
    Dir.mkdir_p(File.join(dir, "bin"))
    Dir.mkdir_p(File.join(shared_vendor_dir, "source"))

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
printf "status\tcomplete\nincomplete_count\t0\n"
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
          "PORT_PARSER"           => "regex",
          "VENDOR_DIR"            => shared_vendor_dir,
        }
      )

      status.success?.should be_true, error_io.to_s

      log = File.read(log_path)
      log.should contain("facts:--language typescript --dir #{shared_vendor_dir}/source")
      log.should contain("facts:--language crystal --dir #{dir}/src")
    ensure
      FileUtils.rm_rf(dir)
      FileUtils.rm_rf(shared_vendor_dir)
    end
  end

  it "falls back to the primary checkout vendor directory for linked worktrees" do
    main_dir = File.join(Dir.tempdir, "chiasmus-main-checkout-#{Random::Secure.hex(8)}")
    worktree_dir = File.join(Dir.tempdir, "chiasmus-linked-worktree-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(main_dir)

    begin
      Process.run("git", ["init", main_dir]).success?.should be_true
      Process.run("git", ["-C", main_dir, "config", "user.email", "spec@example.com"]).success?.should be_true
      Process.run("git", ["-C", main_dir, "config", "user.name", "Spec Runner"]).success?.should be_true

      File.write(File.join(main_dir, "README.md"), "# temp repo\n")
      Process.run("git", ["-C", main_dir, "add", "README.md"]).success?.should be_true
      Process.run("git", ["-C", main_dir, "-c", "commit.gpgsign=false", "commit", "-m", "initial commit"]).success?.should be_true
      Process.run("git", ["-C", main_dir, "worktree", "add", "-b", "linked-spec", worktree_dir, "HEAD"]).success?.should be_true

      Dir.mkdir_p(File.join(main_dir, "vendor", "source"))
      Dir.mkdir_p(File.join(worktree_dir, "src"))
      Dir.mkdir_p(File.join(worktree_dir, "plans", "inventory"))
      Dir.mkdir_p(File.join(worktree_dir, "bin"))

      inventory_path = File.join(worktree_dir, "plans", "inventory", "port.tsv")
      File.write(inventory_path, <<-TSV)
# source_id	kind	status	crystal_refs	notes
src/app.ts::function::main	function	ported	src/main.cr:1,spec/main_spec.cr:1	Covered
TSV

      log_path = File.join(worktree_dir, "tool.log")
      facts_bin = File.join(worktree_dir, "bin", "fake-facts")
      complete_bin = File.join(worktree_dir, "bin", "fake-complete")

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
printf "status\tcomplete\nincomplete_count\t0\n"
SH
      File.chmod(facts_bin, 0o755_i32)
      File.chmod(complete_bin, 0o755_i32)

      script = File.expand_path("../../scripts/check_completion_gate.sh", __DIR__)
      output_io = IO::Memory.new
      error_io = IO::Memory.new
      status = Process.run(
        "bash",
        [script, worktree_dir, inventory_path, "vendor/source", "typescript", "src"],
        output: output_io,
        error: error_io,
        env: {
          "CHIASMUS_FACTS_BIN"    => facts_bin,
          "CHIASMUS_COMPLETE_BIN" => complete_bin,
          "PORT_CRYSTAL_DIRS"     => "src:spec",
          "PORT_PARSER"           => "regex",
        }
      )

      status.success?.should be_true, error_io.to_s

      expected_vendor_source = File.realpath(File.join(main_dir, "vendor", "source"))
      log = File.read(log_path)
      log.should contain("facts:--language typescript --dir #{expected_vendor_source}")
      log.should contain("facts:--language crystal --dir #{worktree_dir}/src")
    ensure
      FileUtils.rm_rf(main_dir)
      FileUtils.rm_rf(worktree_dir)
    end
  end
end
