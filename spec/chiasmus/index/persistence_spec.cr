require "spec"
require "json"
require "file_utils"
require "../../../src/chiasmus/index/persistence"

include Chiasmus::Index

private def with_temp_dir(& : String ->)
  dir = File.tempname("chiasmus-persist-")
  Dir.mkdir(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir) rescue nil
  end
end

describe FactPersistence do
  describe "save_facts / load_facts roundtrip" do
    it "persists and retrieves facts" do
      with_temp_dir do |dir|
        facts = [
          FactEntry.new(source: "extractor", relation: "defines", args: ["src/a.ts", "main", "function", "1", "0"]),
          FactEntry.new(source: "extractor", relation: "calls", args: ["main", "helper"]),
        ]
        FactPersistence.save_facts(dir, facts).should be_true

        loaded = FactPersistence.load_facts(dir)
        loaded.should eq facts
      end
    end

    it "returns empty array when no facts file exists" do
      with_temp_dir do |dir|
        FactPersistence.load_facts(dir).should be_empty
      end
    end

    it "overwrites on save" do
      with_temp_dir do |dir|
        initial = [FactEntry.new(source: "agent", relation: "annotation", args: ["important"])]
        FactPersistence.save_facts(dir, initial)

        updated = [FactEntry.new(source: "agent", relation: "annotation", args: ["critical"])]
        FactPersistence.save_facts(dir, updated)

        FactPersistence.load_facts(dir).should eq updated
      end
    end
  end

  describe "merge_facts" do
    it "deduplicates by source+relation+args" do
      base = [
        FactEntry.new(source: "extractor", relation: "defines", args: ["a", "f"]),
      ]
      extra = [
        FactEntry.new(source: "extractor", relation: "defines", args: ["a", "f"]),
        FactEntry.new(source: "agent", relation: "annotation", args: ["note"]),
      ]
      merged = FactPersistence.merge_facts(base, extra)
      merged.size.should eq 2
      merged.should contain(FactEntry.new(source: "extractor", relation: "defines", args: ["a", "f"]))
      merged.should contain(FactEntry.new(source: "agent", relation: "annotation", args: ["note"]))
    end
  end

  describe "facts_to_prolog" do
    it "generates Prolog program from facts" do
      facts = [
        FactEntry.new(source: "extractor", relation: "defines", args: ["'src/a.ts'", "main", "function", "1", "0"]),
        FactEntry.new(source: "agent", relation: "important", args: ["'src/a.ts'", "main"]),
      ]
      program = FactPersistence.facts_to_prolog(facts)
      program.should contain("defines('src/a.ts', main, function, 1, 0).")
      program.should contain("% agent: important('src/a.ts', main).")
    end
  end
end
