require "../graph/ir"
require "../graph/port_dom"
require "../graph/types"
require "./reconcile"
require "./rules"

module Chiasmus
  module Parity
    # Compares the typed API surface (via `Graph::PortDom`) of each reconciled
    # source/target pair. Arity is compared always; return types are compared
    # through each side's `type_map` so cross-language spellings
    # (`void`/`Nil`, `int`/`Int32`) match. See `plans/port_dom.md`.
    module Surface
      record SurfaceReport,
        source_id : String,
        target_id : String?,
        status : String,
        arity_match : Bool,
        source_arity : Int32,
        target_arity : Int32,
        return_type_match : Bool,
        source_return : String?,
        target_return : String?,
        details : String

      STATUSES = ["surface_match", "surface_mismatch", "surface_unmodeled"]

      extend self

      def compare(
        source_graph : Graph::CodeGraph,
        target_graph : Graph::CodeGraph,
        mappings : Array(Reconcile::Mapping),
        rules : Rules::RuleSet = Rules::RuleSet.new,
      ) : Array(SurfaceReport)
        source_methods = index_methods(Graph::PortDom.build(source_graph))
        target_methods = index_methods(Graph::PortDom.build(target_graph))
        source_types = TypeNormalizer.new(rules.source.type_map)
        target_types = TypeNormalizer.new(rules.target.type_map)

        mappings.compact_map do |mapping|
          source = source_methods[mapping.source_id]?
          next nil unless source

          target = mapping.target_id.try { |id| target_methods[id]? }
          report_for(mapping, source, target, source_types, target_types)
        end
      end

      private def index_methods(dom : Graph::PortDom::PortDom) : Hash(String, Graph::PortDom::MethodSurface)
        index = {} of String => Graph::PortDom::MethodSurface
        dom.methods.each { |surface| index[surface.symbol_id] = surface }
        index
      end

      private def report_for(
        mapping : Reconcile::Mapping,
        source : Graph::PortDom::MethodSurface,
        target : Graph::PortDom::MethodSurface?,
        source_types : TypeNormalizer,
        target_types : TypeNormalizer,
      ) : SurfaceReport
        unless target
          return SurfaceReport.new(
            source_id: mapping.source_id,
            target_id: mapping.target_id,
            status: "surface_unmodeled",
            arity_match: false,
            source_arity: source.params.size,
            target_arity: 0,
            return_type_match: false,
            source_return: source.return_type.try(&.name),
            target_return: nil,
            details: "no target method surface",
          )
        end

        arity_match = source.params.size == target.params.size
        source_return = source.return_type.try(&.name)
        target_return = target.return_type.try(&.name)

        # Only judge return types when both sides expose one; otherwise arity is
        # the only reliable signal.
        judged = !(source_return.nil? || target_return.nil?)
        return_type_match = if judged
                              source_types.canonical(source_return) == target_types.canonical(target_return)
                            else
                              true
                            end

        # Status is arity-based: cross-language return-type names still differ
        # (class spellings, generics), so a normalized return-type flag is
        # reported for review but does not by itself fail the surface.
        status = arity_match ? "surface_match" : "surface_mismatch"
        details = "arity #{source.params.size}->#{target.params.size}"
        details += " return #{source_return}->#{target_return}" if judged && !return_type_match

        SurfaceReport.new(
          source_id: mapping.source_id,
          target_id: mapping.target_id,
          status: status,
          arity_match: arity_match,
          source_arity: source.params.size,
          target_arity: target.params.size,
          return_type_match: return_type_match,
          source_return: source_return,
          target_return: target_return,
          details: details,
        )
      end

      # Normalizes type names to a canonical token via a side's `type_map`,
      # falling back to a lowercase name when unmapped.
      class TypeNormalizer
        def initialize(type_map : Hash(String, String))
          @lookup = {} of String => String
          type_map.each { |name, canonical| @lookup[name.downcase] = canonical.downcase }
        end

        def canonical(type : String?) : String?
          return nil unless type

          name = type.strip
          return nil if name.empty?

          @lookup[name.downcase]? || name.downcase
        end
      end
    end
  end
end
