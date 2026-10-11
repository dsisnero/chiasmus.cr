require "yaml"
require "./naming"

module Chiasmus
  module Parity
    # Declarative, reviewable rule data for cross-language entity reconciliation.
    #
    # A rule set describes how to turn language-native symbol spellings into a
    # shared canonical key so that "same entity, different spelling" matches
    # without bespoke grep heuristics. It is intentionally direction-aware
    # (source language -> target language) and lives in repo-local config
    # (recommended: `plans/parity_rules.yml`).
    #
    # See `docs/parity-rule-data.md` for authoring guidance and a worked Java
    # (PDFBox) -> Crystal example.
    module Rules
      # One explicit source-name -> target-name rename applied after per-side
      # normalization. Use for identifiers no generic rule can derive.
      struct Rename
        include YAML::Serializable
        include YAML::Serializable::Unmapped

        property source : String
        property target : String

        def initialize(@source : String, @target : String)
        end
      end

      # Many-to-one consolidation: any source name matching the glob `source`
      # maps to `target`. Use for families collapsed into one target symbol
      # (for example contentstream operator classes -> `process_operator`).
      struct Consolidate
        include YAML::Serializable
        include YAML::Serializable::Unmapped

        property source : String
        property target : String
        property reason : String = ""

        def initialize(@source : String, @target : String, @reason : String = "")
        end
      end

      struct Side
        include YAML::Serializable
        include YAML::Serializable::Unmapped

        # Leading qualified-name fragments to strip (for example Java packages).
        property strip_namespace : Array(String) = [] of String

        # Leading simple-name prefixes to strip, longest-first (for example
        # `COS`, `PD`). Only stripped when a residual name remains.
        property strip_prefix : Array(String) = [] of String

        # Strip `get`/`set`/`is` accessor prefixes (only when followed by an
        # uppercase letter or underscore).
        property? strip_accessor : Bool = false

        # Type-name normalization for this side: `name -> canonical`. Used to
        # make cross-language types comparable (e.g. Java `int` -> `int32`,
        # Crystal `Int32` -> `int32`; Java `void` -> `nil`, Crystal `Nil` ->
        # `nil`). Lookup is case-insensitive.
        property type_map : Hash(String, String) = {} of String => String

        def initialize(
          @strip_namespace : Array(String) = [] of String,
          @strip_prefix : Array(String) = [] of String,
          @strip_accessor : Bool = false,
          @type_map : Hash(String, String) = {} of String => String,
        )
        end
      end

      struct RuleSet
        include YAML::Serializable
        include YAML::Serializable::Unmapped

        property version : Int32 = 1
        property source_language : String = ""
        property target_language : String = ""
        # When true, break canonical-key ties using the owner (package / module)
        # leaf before reporting `ambiguous`.
        property? match_owner : Bool = false
        # When true, a member whose strict owner match fails may match a target
        # member under a different owner (inherited/interface members) when the
        # signature arity agrees; such matches carry `basis: member`.
        property? match_inherited : Bool = false
        property source : Side = Side.new
        property target : Side = Side.new
        property renames : Array(Rename) = [] of Rename
        property consolidate : Array(Consolidate) = [] of Consolidate
        # Explicit owner/namespace tie aliases (canonical key -> canonical key),
        # resolved transitively during owner matching. Use for spelling
        # differences no lexical rule can derive (e.g. `pdfwriter` ->
        # `pdf_writer`).
        property owner_aliases : Array(Rename) = [] of Rename

        def initialize(
          @version : Int32 = 1,
          @source_language : String = "",
          @target_language : String = "",
          @match_owner : Bool = false,
          @match_inherited : Bool = false,
          @source : Side = Side.new,
          @target : Side = Side.new,
          @renames : Array(Rename) = [] of Rename,
          @consolidate : Array(Consolidate) = [] of Consolidate,
          @owner_aliases : Array(Rename) = [] of Rename,
        )
        end

        def self.load(path : String) : RuleSet
          from_yaml(File.read(path))
        end

        def self.load_if(path : String?) : RuleSet
          path && File.file?(path) ? load(path) : new
        end
      end

      # Computes canonical keys for symbols on either side of the port.
      class Normalizer
        enum Side
          Source
          Target
        end

        # Provenance of a canonical key, surfaced in reconciliation output.
        enum Basis
          Direct
          Renamed
          Consolidated
        end

        def initialize(@rules : RuleSet)
          @alias_map = {} of String => String
          @rules.owner_aliases.each do |alias_rule|
            @alias_map[Naming.normalize_token(alias_rule.source)] = Naming.normalize_token(alias_rule.target)
          end
        end

        # Resolves an owner/namespace canonical key through the alias map to a
        # fixpoint, so chains (`a -> b -> c`) settle on `c`. Cycle-safe.
        def resolve_alias(key : String) : String
          current = key
          visited = Set(String).new
          while (next_key = @alias_map[current]?) && !visited.includes?(current)
            visited << current
            current = next_key
          end
          current
        end

        def canonical(side : Side, name : String) : String
          canonical_with_basis(side, name)[0]
        end

        def canonical_with_basis(side : Side, name : String) : Tuple(String, String)
          case side
          in .source?
            normalized = normalize(@rules.source, name)
            if rename = @rules.renames.find { |candidate| candidate.source == normalized }
              {key(rename.target), Basis::Renamed.to_s.downcase}
            elsif consolidate = @rules.consolidate.find { |candidate| glob_match?(candidate.source, normalized) }
              {key(consolidate.target), Basis::Consolidated.to_s.downcase}
            else
              {key(normalized), Basis::Direct.to_s.downcase}
            end
          in .target?
            {key(normalize(@rules.target, name)), Basis::Direct.to_s.downcase}
          end
        end

        # Normalized simple name (prefix/accessor stripped) for `side`. This is
        # the value rename/consolidate rules are matched against on the source.
        def normalize(config : Rules::Side, name : String) : String
          stripped = name
          config.strip_namespace.each do |prefix|
            stripped = stripped.lchop(prefix) if stripped.starts_with?(prefix)
          end

          simple = simple_name(stripped)
          if prefix = choose_strip_prefix(config.strip_prefix, simple)
            simple = simple[prefix.bytesize..]
          end

          simple = strip_accessor(simple) if config.strip_accessor?
          simple
        end

        # Chooses one prefix to strip. Prefers the *longest* matching prefix
        # that leaves a valid remainder (non-empty, uppercase- or `_`-leading),
        # so `PDFontLike` backs off from `PDF` (`ontLike`) to `PD` (`FontLike`),
        # while `PDFDocEncoding` keeps `PDF` (`DocEncoding`). Falls back to the
        # longest match when no remainder is valid.
        private def choose_strip_prefix(prefixes : Array(String), name : String) : String?
          matching = prefixes.select { |prefix| name.starts_with?(prefix) && name.bytesize > prefix.bytesize }
          return nil if matching.empty?

          valid = matching.select do |prefix|
            first = name[prefix.bytesize]?
            first ? (first.uppercase? || first == '_') : false
          end
          return valid.max_by(&.bytesize) unless valid.empty?

          matching.max_by(&.bytesize)
        end

        def key(name : String) : String
          Naming.normalize_token(name)
        end

        private def simple_name(name : String) : String
          segments = name.split(/::|\./)
          segments.reject(&.empty?).last? || name
        end

        private def strip_accessor(name : String) : String
          %w[is get set].each do |prefix|
            next unless name.starts_with?(prefix) && name.bytesize > prefix.bytesize
            following = name[prefix.bytesize]
            next unless following.uppercase? || following == '_'
            rest = name[prefix.bytesize..]
            rest = rest.lchop('_') if rest.starts_with?('_')
            return rest unless rest.empty?
          end
          name
        end

        # Anchored glob match supporting `*` wildcards.
        private def glob_match?(pattern : String, value : String) : Bool
          return true if pattern == value
          return false unless pattern.includes?('*')

          escaped = Regex.escape(pattern).gsub("\\*", ".*")
          value.matches?(/\A#{escaped}\z/)
        end
      end
    end
  end
end
