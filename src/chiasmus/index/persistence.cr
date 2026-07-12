require "json"

module Chiasmus
  module Index
    # A single fact entry from any source.
    record FactEntry,
      source : String,
      relation : String,
      args : Array(String) do
      include JSON::Serializable

      def to_prolog : String
        escaped_args = args.join(", ")
        if source == "extractor"
          "#{relation}(#{escaped_args})."
        else
          "% #{source}: #{relation}(#{escaped_args})."
        end
      end

      def merge_key : String
        "#{source}::#{relation}::#{args.join("::")}"
      end
    end

    # Persistence for Prolog facts and agent-derived facts.
    #
    # Facts are stored as JSON at `<root>/.chiasmus/facts.json`.
    # Agent-derived facts are prefixed with `% agent:` in Prolog output
    # so they act as comments but are reconstructible.
    module FactPersistence
      FACTS_FILE = ".chiasmus/facts.json"

      extend self

      # Save facts to file. Returns true on success.
      def save_facts(root : String, facts : Array(FactEntry)) : Bool
        dir = File.join(root, ".chiasmus")
        Dir.mkdir_p(dir)
        path = File.join(dir, "facts.json")
        File.write(path, facts.to_json)
        true
      rescue
        false
      end

      # Load facts from file. Returns empty array if file doesn't exist.
      def load_facts(root : String) : Array(FactEntry)
        path = File.join(root, FACTS_FILE)
        return [] of FactEntry unless File.exists?(path)
        Array(FactEntry).from_json(File.read(path))
      rescue
        [] of FactEntry
      end

      # Merge new facts into existing, deduplicating by merge_key.
      # Existing facts with the same source+relation+args are preserved.
      def merge_facts(existing : Array(FactEntry), incoming : Array(FactEntry)) : Array(FactEntry)
        seen = Set(String).new
        (existing + incoming).select do |fact|
          seen.add?(fact.merge_key)
        end
      end

      # Convert facts to a Prolog program string.
      # Extractor facts become plain Prolog clauses.
      # Agent/other source facts become commented lines for reconstructability.
      def facts_to_prolog(facts : Array(FactEntry)) : String
        facts.map(&.to_prolog).join("\n")
      end
    end
  end
end
