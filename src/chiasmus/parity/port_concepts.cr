require "json"
require "openssl"
require "./reconcile"
require "../graph/file_extraction"

module Chiasmus
  module Parity
    # A compatibility sidecar for reviewed cross-language correspondences.
    # Legacy fact IDs contain paths, so they are retained as references rather
    # than used as the stable concept key. Typed declaration IDs join only by
    # exact legacy aliases, never by a name-only fallback.
    module PortConcepts
      VERSION = 1

      class TypedIndex
        def self.load(path : String?, language : String) : self
          index = new
          return index unless path

          File.each_line(path) do |line|
            next if line.strip.empty?

            Graph::FileExtraction::Result.from_json(line).declarations.each do |declaration|
              next unless language.empty? || declaration.language == language

              index.add(declaration)
            end
          end
          index
        end

        def initialize
          @aliases = Hash(String, Array(String?)).new { |hash, key| hash[key] = [] of String? }
        end

        def add(declaration : Graph::FileExtraction::Declaration) : Nil
          declaration.legacy_aliases.each { |legacy_alias| @aliases[legacy_alias] << declaration.declaration_id }
        end

        def declaration_id(legacy_id : String?) : String?
          return nil unless legacy_id
          values = @aliases[legacy_id]?
          values && values.size == 1 ? values.first : nil
        end
      end

      extend self

      def render(output : IO, mappings : Array(Reconcile::Mapping), source : Graph::CodeGraph, target : Graph::CodeGraph, rules : Rules::RuleSet, source_typed : TypedIndex = TypedIndex.new, target_typed : TypedIndex = TypedIndex.new) : Nil
        normalizer = Rules::Normalizer.new(rules)
        source_counts = semantic_counts(source)
        target_counts = semantic_counts(target)
        source_index = fact_index(source)
        target_index = fact_index(target)
        target_uses = Hash(String, Int32).new(0)
        mappings.each do |mapping|
          if mapping.status == "matched" && (target_id = mapping.target_id)
            target_uses[target_id] += 1
          end
        end

        mappings.each do |mapping|
          concept_id = concept_id_for(mapping, source_index, target_index, rules, normalizer, source_counts, target_counts, target_uses)

          output.puts({
            schema_version:        VERSION,
            source_id:             mapping.source_id,
            source_name:           mapping.source_name,
            source_kind:           mapping.source_kind,
            target_id:             mapping.target_id,
            target_name:           mapping.target_name,
            target_kind:           mapping.target_kind,
            source_declaration_id: source_typed.declaration_id(mapping.source_id),
            target_declaration_id: target_typed.declaration_id(mapping.target_id),
            port_concept_id:       concept_id,
            status:                mapping.status,
            basis:                 mapping.basis,
            provenance:            concept_id ? "explicit_rename_rule" : "none",
          }.to_json)
        end
      end

      private def concept_id_for(
        mapping : Reconcile::Mapping,
        source_index : Hash(String, Graph::DefinesFact),
        target_index : Hash(String, Graph::DefinesFact),
        rules : Rules::RuleSet,
        normalizer : Rules::Normalizer,
        source_counts : Hash(String, Int32),
        target_counts : Hash(String, Int32),
        target_uses : Hash(String, Int32),
      ) : String?
        return nil unless mapping.status == "matched" && mapping.basis != "consolidated"
        return nil unless reviewed_rename?(mapping, rules, normalizer)
        return nil unless target_id = mapping.target_id
        return nil unless target_uses[target_id] == 1
        return nil unless source_fact = source_index[mapping.source_id]?
        return nil unless target_fact = target_index[target_id]?
        return nil unless source_counts[semantic_key(source_fact)] == 1 && target_counts[semantic_key(target_fact)] == 1

        stable_id(rules, source_fact, target_fact)
      end

      private def reviewed_rename?(mapping : Reconcile::Mapping, rules : Rules::RuleSet, normalizer : Rules::Normalizer) : Bool
        return false unless target_name = mapping.target_name

        normalized_source = normalizer.normalize(rules.source, mapping.source_name)
        normalized_target = normalizer.canonical(Rules::Normalizer::Side::Target, target_name)
        rules.renames.any? { |rule| rule.source == normalized_source && normalizer.key(rule.target) == normalized_target }
      end

      private def semantic_counts(graph : Graph::CodeGraph) : Hash(String, Int32)
        counts = Hash(String, Int32).new(0)
        graph.defines.each { |fact| counts[semantic_key(fact)] += 1 }
        counts
      end

      private def fact_index(graph : Graph::CodeGraph) : Hash(String, Graph::DefinesFact)
        index = {} of String => Graph::DefinesFact
        graph.defines.each { |fact| index[Reconcile.entity_id(fact)] = fact }
        index
      end

      private def semantic_key(fact : Graph::DefinesFact) : String
        {fact.kind.to_prolog_atom, Reconcile.display_name(fact), fact.signature}.to_json
      end

      private def stable_id(rules : Rules::RuleSet, source : Graph::DefinesFact, target : Graph::DefinesFact) : String
        fields = {
          "port:v1",
          rules.source_language,
          semantic_key(source),
          rules.target_language,
          semantic_key(target),
        }
        "port:v1:#{OpenSSL::Digest.new("SHA256").update(fields.to_json).final.hexstring}"
      end
    end
  end
end
