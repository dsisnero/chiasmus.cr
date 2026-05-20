# Ported from vendor/chiasmus/src/graph/analyses.ts
#
# Layer violation detection: calls that skip architectural layers.
# LAYER_ORDER defines known layers; a call is a violation when
# callee is >1 layer deeper than caller (e.g. handler → db).

require "./types"

module Chiasmus
  module Graph
    record LayerViolationResult,
      caller : String,
      callee : String,
      caller_layer : String,
      callee_layer : String

    # Layer ordering: lower number = outer layer.
    # handlers/routes/controllers → services → repositories → db/models
    LAYER_ORDER = {
      "handlers"     => 0,
      "routes"       => 0,
      "controllers"  => 0,
      "services"     => 1,
      "repositories" => 2,
      "db"           => 3,
      "models"       => 3,
    }

    module LayerViolation
      extend self

      private def extract_layer(file_path : String) : String?
        normalized = file_path.gsub('\\', '/')
        segments = normalized.split('/')
        segments.each do |seg|
          return seg if LAYER_ORDER.has_key?(seg)
        end
        nil
      end

      def find(graph : CodeGraph) : Array(LayerViolationResult)
        func_layers = Hash(String, String).new
        graph.defines.each do |d|
          layer = extract_layer(d.file)
          func_layers[d.name] = layer if layer
        end

        violations = [] of LayerViolationResult
        graph.calls.each do |c|
          caller_layer = func_layers[c.caller]?
          callee_layer = func_layers[c.callee]?
          next unless caller_layer && callee_layer
          next if caller_layer == callee_layer

          caller_order = LAYER_ORDER[caller_layer]? || 0
          callee_order = LAYER_ORDER[callee_layer]? || 0

          if callee_order - caller_order > 1
            violations << LayerViolationResult.new(
              caller: c.caller,
              callee: c.callee,
              caller_layer: caller_layer,
              callee_layer: callee_layer,
            )
          end
        end

        violations
      end
    end
  end
end
