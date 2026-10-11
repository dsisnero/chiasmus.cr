require "./rules"
require "../graph/port_dom"
require "../graph/types"

module Chiasmus
  module Parity
    # Cross-language entity reconciliation: turns a source graph and a target
    # graph into a `maps_to`-style join after applying `Rules`. This is the
    # principled replacement for name-only matching and ad-hoc snake_case
    # heuristics; reconciles "same entity, different spelling" and makes genuine
    # gaps (and ambiguous name collisions) visible mechanically.
    module Reconcile
      record Mapping,
        source_id : String,
        source_name : String,
        source_kind : String,
        canonical : String,
        target_id : String? = nil,
        target_name : String? = nil,
        target_kind : String? = nil,
        status : String = "unmapped_source",
        basis : String = "direct",
        source_owner : String? = nil,
        target_owner : String? = nil

      # `matched`     — exactly one compatible target for the canonical key
      # `ambiguous`   — more than one compatible target (needs a rename rule)
      # `unmapped_source` — no compatible target
      STATUSES = ["matched", "ambiguous", "unmapped_source"]

      # Kinds that may legitimately correspond to one another across languages.
      COMPATIBLE_KINDS = {
        "function"  => ["function", "method"],
        "method"    => ["method", "function"],
        "class"     => ["class", "module", "struct", "interface"],
        "interface" => ["interface", "module", "class"],
        "type"      => ["type", "class", "module", "struct", "alias"],
        "module"    => ["module", "class"],
        "variable"  => ["variable", "const", "constant"],
      }

      extend self

      def mappings(source : Graph::CodeGraph, target : Graph::CodeGraph, rules : Rules::RuleSet) : Array(Mapping)
        normalizer = Rules::Normalizer.new(rules)
        index = Hash(String, Array(Graph::DefinesFact)).new { |hash, key| hash[key] = [] of Graph::DefinesFact }
        target.defines.each do |fact|
          index[normalizer.canonical(Rules::Normalizer::Side::Target, display_name(fact))] << fact
        end

        source_contains = build_owner_index(source)
        target_contains = build_owner_index(target)

        source.defines.map do |fact|
          name = display_name(fact)
          canonical, basis = normalizer.canonical_with_basis(Rules::Normalizer::Side::Source, name)
          source_kind = kind(fact)
          source_owner = owner_key(normalizer, Rules::Normalizer::Side::Source, rules.source, owner_of(fact, source_contains))
          target_owner = nil

          candidates, basis = resolve_candidates(index, canonical, fact, source_kind, source_owner, basis, normalizer, rules, target_contains)

          status, match = classify(candidates)
          if match
            target_owner = owner_key(normalizer, Rules::Normalizer::Side::Target, rules.target, owner_of(match, target_contains))
            basis = "owner" if status == "matched" && source_owner && target_owner == source_owner
          end

          Mapping.new(
            source_id: entity_id(fact),
            source_name: name,
            source_kind: source_kind,
            canonical: canonical,
            target_id: match.try { |value| entity_id(value) },
            target_name: match.try { |value| display_name(value) },
            target_kind: match.try { |value| kind(value) },
            status: status,
            basis: basis,
            source_owner: source_owner,
            target_owner: target_owner,
          )
        end
      end

      def display_name(fact : Graph::DefinesFact) : String
        fact.qualified_name || fact.name
      end

      def entity_id(fact : Graph::DefinesFact) : String
        "#{fact.file}::#{kind(fact)}::#{display_name(fact)}"
      end

      def compatible?(source_kind : String, target_kind : String) : Bool
        return true if source_kind == target_kind

        (COMPATIBLE_KINDS[source_kind]? || [] of String).includes?(target_kind)
      end

      # Kinds eligible for the inherited/interface fallback. Restricted to
      # callables: they carry a signature for the arity guardrail, whereas
      # variables/consts have none and would collide on leaf name alone.
      def member_kind?(kind : String) : Bool
        kind.in?("method", "function")
      end

      # For the inherited fallback, require *both* sides to expose a signature
      # with the same arity. This keeps the fallback conservative (name + arity
      # only) and stops coincidental same-name matches.
      private def narrow_by_signature(candidates : Array(Graph::DefinesFact), source : Graph::DefinesFact) : Array(Graph::DefinesFact)
        arity = param_count(source.signature)
        return [] of Graph::DefinesFact unless arity

        candidates.select { |candidate| param_count(candidate.signature) == arity }
      end

      private def param_count(signature : String?) : Int32?
        return nil unless signature

        params, _ = Graph::PortDom.parse_signature(signature)
        params.size
      end

      # Applies kind compatibility, owner-aware filtering, the inherited-member
      # fallback, and the kind-aware tie-break, returning the surviving
      # candidates and the (possibly updated) basis.
      private def resolve_candidates(
        index : Hash(String, Array(Graph::DefinesFact)),
        canonical : String,
        fact : Graph::DefinesFact,
        source_kind : String,
        source_owner : String?,
        basis : String,
        normalizer : Rules::Normalizer,
        rules : Rules::RuleSet,
        target_contains : Hash(String, Set(String)),
      ) : Tuple(Array(Graph::DefinesFact), String)
        candidates = index[canonical]? || [] of Graph::DefinesFact
        # Consolidation rules are explicit author intent and may intentionally
        # cross kinds (operator classes -> a dispatch method), so they bypass the
        # kind-compatibility filter.
        candidates = candidates.select { |candidate| compatible?(source_kind, kind(candidate)) } unless basis == "consolidated"

        if rules.match_owner? && source_owner
          candidates = filter_by_owner(candidates, source_owner, normalizer, rules, target_contains)
        end

        if candidates.empty? && rules.match_inherited? && source_owner && member_kind?(source_kind)
          if relaxed = inherited_candidates(index, canonical, fact, source_kind, normalizer, rules, target_contains)
            candidates = relaxed
            basis = "member"
          end
        end

        candidates = narrow_by_exact_kind(candidates, source_kind) if candidates.size > 1 && basis != "member"
        {candidates, basis}
      end

      # Owner-aware matching: a known, conflicting owner is a non-match; an
      # unknown owner stays eligible, so missing owner data degrades to name-only
      # matching rather than dropping real matches.
      private def filter_by_owner(
        candidates : Array(Graph::DefinesFact),
        source_owner : String,
        normalizer : Rules::Normalizer,
        rules : Rules::RuleSet,
        target_contains : Hash(String, Set(String)),
      ) : Array(Graph::DefinesFact)
        candidates.select do |candidate|
          candidate_owner = owner_key(normalizer, Rules::Normalizer::Side::Target, rules.target, owner_of(candidate, target_contains))
          candidate_owner.nil? || candidate_owner == source_owner
        end
      end

      # Inherited/interface members: a base-type member corresponds to a target
      # member under a different (concrete) owner. Only returns candidates when
      # the canonical member is spread across *multiple* distinct target owners
      # (the interface signature) and arity agrees; a name under a single
      # unrelated owner is a coincidence, not an inherited member.
      private def inherited_candidates(
        index : Hash(String, Array(Graph::DefinesFact)),
        canonical : String,
        fact : Graph::DefinesFact,
        source_kind : String,
        normalizer : Rules::Normalizer,
        rules : Rules::RuleSet,
        target_contains : Hash(String, Set(String)),
      ) : Array(Graph::DefinesFact)?
        relaxed = (index[canonical]? || [] of Graph::DefinesFact).select { |candidate| compatible?(source_kind, kind(candidate)) }
        relaxed = narrow_by_signature(relaxed, fact)
        distinct_owners = relaxed.compact_map do |candidate|
          owner_key(normalizer, Rules::Normalizer::Side::Target, rules.target, owner_of(candidate, target_contains))
        end
        distinct_owners.uniq.size >= 2 ? relaxed : nil
      end

      private def narrow_by_exact_kind(candidates : Array(Graph::DefinesFact), source_kind : String) : Array(Graph::DefinesFact)
        exact_kind = candidates.select { |candidate| kind(candidate) == source_kind }
        exact_kind.size == 1 ? exact_kind : candidates
      end

      # Resolved owner (package / module) key for every definition, keyed by
      # `entity_id`. Used by the Prolog projection so entities carry identity.
      def owners(graph : Graph::CodeGraph, rules : Rules::RuleSet, side : Rules::Normalizer::Side) : Hash(String, String)
        normalizer = Rules::Normalizer.new(rules)
        contains = build_owner_index(graph)
        config = side.source? ? rules.source : rules.target
        result = {} of String => String
        graph.defines.each do |fact|
          key = owner_key(normalizer, side, config, owner_of(fact, contains))
          result[entity_id(fact)] = key if key
        end
        result
      end

      # Resolves a symbol's owner (package / module) for owner-aware matching:
      # the qualified-name owner part, the `contains` parent, or the enclosing
      # directory name (Java package leaf) as a final fallback.
      private def owner_of(
        fact : Graph::DefinesFact,
        contains_index : Hash(String, Set(String)),
      ) : String?
        if qualified = fact.qualified_name
          if owner = owner_part(qualified)
            return owner
          end
        end

        parent = unique_parent(contains_index, fact.qualified_name || fact.name)
        return parent if parent

        # Top-level class with no namespace in the facts: fall back to the
        # enclosing directory name, which carries the package / module leaf.
        File.dirname(fact.file).split('/').reject(&.empty?).last?
      rescue
        nil
      end

      private def owner_key(
        normalizer : Rules::Normalizer,
        side : Rules::Normalizer::Side,
        config : Rules::Side,
        owner : String?,
      ) : String?
        return nil unless owner
        leaf = owner.split(/::|\./).reject(&.empty?).last?
        return nil unless leaf
        normalizer.resolve_alias(normalizer.key(normalizer.normalize(config, leaf)))
      end

      private def owner_part(qualified : String) : String?
        segments = qualified.split(/::|\./).reject(&.empty?)
        return nil if segments.size < 2
        segments[0...-1].join(".")
      end

      private def build_owner_index(graph : Graph::CodeGraph) : Hash(String, Set(String))
        index = Hash(String, Set(String)).new { |hash, key| hash[key] = Set(String).new }
        graph.contains.each do |fact|
          index[fact.child] << fact.parent
          index[simple_name(fact.child)] << fact.parent
        end
        index
      end

      private def unique_parent(index : Hash(String, Set(String)), child : String) : String?
        parents = index[child]?
        return nil unless parents && parents.size == 1
        parents.first
      end

      private def simple_name(name : String) : String
        name.split(/::|\./).reject(&.empty?).last? || name
      end

      private def kind(fact : Graph::DefinesFact) : String
        fact.kind.to_s.downcase
      end

      private def classify(candidates : Array(Graph::DefinesFact)) : Tuple(String, Graph::DefinesFact?)
        case candidates.size
        when 0 then {"unmapped_source", nil}
        when 1 then {"matched", candidates.first}
        else        {"ambiguous", nil}
        end
      end
    end
  end
end
