require "spec"
require "../spec_helper"
require "../support/complete_fixture"

describe "chiasmus-complete artifact rendering" do
  it "matches the repo bundle completion TSV files from in-memory evaluation" do
    dir = build_chiasmus_complete_repo_bundle

    evaluation = Chiasmus::Complete.evaluate(
      inventory_path: File.join(Dir.current, "plans", "inventory", "typescript_port_inventory.tsv"),
      root_dir: Dir.current,
      source_facts_path: File.join(dir, "source_facts.pl"),
      parity_report_path: File.join(dir, "parity.tsv"),
    )

    status_output = IO::Memory.new
    incomplete_output = IO::Memory.new

    Chiasmus::Complete.render_status(status_output, evaluation)
    Chiasmus::Complete.render_rows(
      incomplete_output,
      evaluation,
      evaluation.incomplete_ids,
      Chiasmus::Complete::OutputFormat::Tsv
    )

    status_output.to_s.should eq(File.read(File.join(dir, "completion_status.tsv")))
    incomplete_output.to_s.should eq(File.read(File.join(dir, "completion_incomplete.tsv")))
  end
end
