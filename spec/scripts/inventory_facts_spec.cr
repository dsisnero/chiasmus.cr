require "../spec_helper"
require "file_utils"

describe "generate_inventory_facts.rb" do
  it "generates Prolog facts from inventory and conversion rules" do
    dir = File.join(Dir.tempdir, "chiasmus-facts-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      inventory_path = File.join(dir, "inventory.tsv")
      rules_path = File.join(dir, "rules.tsv")

      File.write(inventory_path, <<-TSV)
# source_id\tkind\tstatus\tcrystal_refs\tnotes
src/llm/anthropic.ts::class::AnthropicAdapter\tclass\tintentional_divergence\t-\tReplaced by Crig
src/graph/extractor.ts::function::extractGraph\tfunction\tported\tsrc/chiasmus/graph/extractor.cr:13\tPorted
TSV

      File.write(rules_path, <<-TSV)
typescript\tcrystal\tLLMAdapter\tCrig agent\tUpstream LLM adapters replaced by Crig
TSV

      script = File.expand_path("../../scripts/generate_inventory_facts.rb", __DIR__)

      output_io = IO::Memory.new
      error_io = IO::Memory.new
      status = Process.run(
        "ruby",
        [script,
         "--inventory", inventory_path,
         "--rules", rules_path],
        output: output_io,
        error: error_io
      )

      status.success?.should be_true, error_io.to_s

      facts = output_io.to_s

      # inventory_item facts for each row
      facts.should contain("inventory_item('src/llm/anthropic.ts::class::AnthropicAdapter'")
      facts.should contain("inventory_item('src/graph/extractor.ts::function::extractGraph'")

      # status fact
      facts.should contain("status('src/llm/anthropic.ts::class::AnthropicAdapter', 'intentional_divergence')")

      # intentional_divergence fact
      facts.should contain("intentional_divergence('src/llm/anthropic.ts::class::AnthropicAdapter', 'Replaced by Crig')")

      # ported_item fact
      facts.should contain("ported_item('src/graph/extractor.ts::function::extractGraph')")

      # conversion_rule fact
      facts.should contain("conversion_rule('typescript', 'crystal', 'LLMAdapter', 'Crig agent', 'Upstream LLM adapters replaced by Crig')")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "does not generate missing_item for ported items" do
    dir = File.join(Dir.tempdir, "chiasmus-facts-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      inventory_path = File.join(dir, "inventory.tsv")

      File.write(inventory_path, <<-TSV)
# source_id\tkind\tstatus\tcrystal_refs\tnotes
src/example.ts::function::foo\tfunction\tported\tsrc/example.cr:1\tDone
TSV

      script = File.expand_path("../../scripts/generate_inventory_facts.rb", __DIR__)

      output_io = IO::Memory.new
      error_io = IO::Memory.new
      status = Process.run(
        "ruby",
        [script, "--inventory", inventory_path],
        output: output_io,
        error: error_io
      )

      status.success?.should be_true, error_io.to_s

      facts = output_io.to_s
      facts.should contain("ported_item(")
      facts.should_not contain("missing_item(")
      facts.should_not contain("partial_item(")
      facts.should_not contain("intentional_divergence(")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "generates intentional_divergence facts from conversion rules independently" do
    dir = File.join(Dir.tempdir, "chiasmus-facts-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      rules_path = File.join(dir, "rules.tsv")
      inventory_path = File.join(dir, "inventory.tsv")

      File.write(inventory_path, "# source_id\tkind\tstatus\tcrystal_refs\tnotes\n")
      File.write(rules_path, <<-TSV)
typescript\tcrystal\tBM25Index\tBm25::SearchEngine\tBM25 shard replacement
typescript\tcrystal\tPrologSession\tcrolog\tSWI-Prolog via crolog
TSV

      script = File.expand_path("../../scripts/generate_inventory_facts.rb", __DIR__)

      output_io = IO::Memory.new
      status = Process.run(
        "ruby",
        [script, "--inventory", inventory_path, "--rules", rules_path],
        output: output_io,
        error: Process::Redirect::Close
      )
      status.success?.should be_true

      facts = output_io.to_s
      facts.should contain("conversion_rule('typescript', 'crystal', 'BM25Index', 'Bm25::SearchEngine'")
      facts.should contain("conversion_rule('typescript', 'crystal', 'PrologSession', 'crolog'")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "deterministic: same inputs produce same outputs" do
    dir = File.join(Dir.tempdir, "chiasmus-facts-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      inventory_path = File.join(dir, "inventory.tsv")
      rules_path = File.join(dir, "rules.tsv")

      File.write(inventory_path, <<-TSV)
# source_id\tkind\tstatus\tcrystal_refs\tnotes
src/llm/types.ts::interface::LLMAdapter\tinterface\tintentional_divergence\t-\tReplaced
src/solvers/prolog.ts::function::solve\tfunction\tported\tsrc/chiasmus/solvers/prolog.cr:10\tDone
TSV

      File.write(rules_path, <<-TSV)
typescript\tcrystal\tLLMAdapter\tCrig agent\tLLM replacement
TSV

      script = File.expand_path("../../scripts/generate_inventory_facts.rb", __DIR__)

      out1 = IO::Memory.new
      out2 = IO::Memory.new
      Process.run("ruby", [script, "--inventory", inventory_path, "--rules", rules_path], output: out1)
      Process.run("ruby", [script, "--inventory", inventory_path, "--rules", rules_path], output: out2)

      out1.to_s.should eq(out2.to_s)
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "does not edit curated inventory" do
    dir = File.join(Dir.tempdir, "chiasmus-facts-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(dir)
    begin
      inventory_path = File.join(dir, "inventory.tsv")

      original = <<-TSV
# source_id\tkind\tstatus\tcrystal_refs\tnotes
src/example.ts::function::main\tfunction\tported\tsrc/example.cr:42\tfast path
TSV

      File.write(inventory_path, original)

      script = File.expand_path("../../scripts/generate_inventory_facts.rb", __DIR__)
      Process.run("ruby", [script, "--inventory", inventory_path], output: IO::Memory.new)

      File.read(inventory_path).should eq(original)
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
