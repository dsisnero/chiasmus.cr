require "../spec_helper"
require "file_utils"

describe "upstream fingerprint scripts" do
  it "reports same-id upstream body changes without editing inventory" do
    dir = File.join(Dir.tempdir, "chiasmus-fingerprints-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      source_dir = File.join(dir, "vendor")
      Dir.mkdir_p(File.join(source_dir, "src"))
      file_path = File.join(source_dir, "src/example.ts")

      File.write(file_path, <<-TS)
      export function solve(value: number) {
        return value + 1;
      }
      TS

      old_path = File.join(dir, "old.tsv")
      new_path = File.join(dir, "new.tsv")
      report_path = File.join(dir, "report.tsv")

      generate = File.expand_path("../../scripts/generate_upstream_fingerprints.rb", __DIR__)
      compare = File.expand_path("../../scripts/compare_upstream_fingerprints.rb", __DIR__)

      old_error = IO::Memory.new
      old_status = Process.run(
        "ruby",
        [generate, "--root", dir, "--source", source_dir, "--language", "typescript", "--parser", "regex", "--out", old_path],
        output: Process::Redirect::Close,
        error: old_error
      )
      old_status.success?.should be_true, old_error.to_s

      File.write(file_path, <<-TS)
      export function solve(value: number) {
        return value + 2;
      }
      TS

      new_error = IO::Memory.new
      new_status = Process.run(
        "ruby",
        [generate, "--root", dir, "--source", source_dir, "--language", "typescript", "--parser", "regex", "--out", new_path],
        output: Process::Redirect::Close,
        error: new_error
      )
      new_status.success?.should be_true, new_error.to_s

      compare_error = IO::Memory.new
      compare_status = Process.run(
        "ruby",
        [compare, "--old", old_path, "--new", new_path, "--out", report_path],
        output: Process::Redirect::Close,
        error: compare_error
      )
      compare_status.success?.should be_true, compare_error.to_s

      report = File.read(report_path)
      report.should contain("changed\tsrc/example.ts::function::solve")
      report.should contain("item fingerprint changed")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
