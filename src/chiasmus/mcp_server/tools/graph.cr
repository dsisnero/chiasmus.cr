# chiasmus_graph tool - Analyze source code call graphs via tree-sitter + Prolog
require "mcp"
require "../types"
require "../tool_schemas"
require "../../graph/analyses"

module Chiasmus
  module MCPServer
    module Tools
      class GraphTool
        private def error_response(message : String) : Hash(String, JSON::Any)
          JSON.parse(Types::ErrorResponse.new(message).to_json).as_h
        end

        def invoke(arguments : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
          files = arguments["files"]?.try(&.as_a?.try(&.map(&.as_s?)))
          analysis = arguments["analysis"]?.try(&.as_s?)
          target = arguments["target"]?.try(&.as_s?)
          from = arguments["from"]?.try(&.as_s?)
          to = arguments["to"]?.try(&.as_s?)
          entry_points = arguments["entry_points"]?.try(&.as_a?.try(&.map(&.as_s)).try(&.compact))

          return error_response("Missing required parameters: files and analysis") unless files && analysis

          # Convert to absolute paths
          absolute_files = files.compact.map { |f| File.expand_path(f) }

          # Validate analysis type
          unless Graph::AnalysisType.parse?(analysis)
            return error_response("Unknown analysis: #{analysis}. Must be one of: summary, callers, callees, reachability, dead-code, cycles, path, impact, facts")
          end

          analysis_type = Graph::AnalysisType.parse(analysis)

          # Run analysis
          request = Graph::AnalysisRequest.new(
            analysis: analysis_type,
            target: target,
            from: from,
            to: to,
            entry_points: entry_points
          )

          result = Graph::Analyses.run_analysis(absolute_files, request)

          # For facts analysis, we know it returns a string (Prolog facts)
          # For other analyses, we need to handle the tagged JSON structure
          result_value = if analysis == "facts"
                           # Facts analysis returns a string directly
                           result.result.as(String)
                         else
                           # Other analyses return tagged JSON
                           result.to_json
                         end

          {
            "status"   => JSON::Any.new("success"),
            "analysis" => JSON::Any.new(analysis),
            "result"   => JSON::Any.new(result_value),
          }
        rescue ex : File::NotFoundError
          error_response("File not found: #{ex.message}")
        rescue ex
          error_response(ex.message || ex.class.name)
        end

        def self.tool_name : String
          "chiasmus_graph"
        end

        def self.tool_description : String
          <<-DESC
          Analyze source code call graphs via tree-sitter + Prolog.

          Parse source files → extract call graph → run formal analysis.
          Supports: TypeScript, JavaScript, Python, Go, Clojure. Files must be absolute paths.

          ANALYSES:
            summary      — overview: files, functions, call edges
            callers      — who calls target? (needs target)
            callees      — what does target call? (needs target)
            reachability — can from reach to? (needs from, to)
            dead-code    — functions unreachable from entry points
            cycles       — circular call dependencies
            path         — call chain from→to (needs from, to)
            impact       — what breaks if target changes? (needs target)
            facts        — raw Prolog facts for custom queries via chiasmus_verify
          DESC
        end

        def self.input_schema : MCP::Protocol::Tool::Input
          ToolSchemas::ToolInputSchema.new(
            properties: {
              "files"        => ToolSchemas::Common.files_property,
              "analysis"     => ToolSchemas::Common.analysis_property,
              "target"       => ToolSchemas::Common.target_property,
              "from"         => ToolSchemas::Common.from_property,
              "to"           => ToolSchemas::Common.to_property,
              "entry_points" => ToolSchemas::Common.entry_points_property,
            },
            required: ["files", "analysis"]
          ).to_mcp_input
        end
      end
    end
  end
end
