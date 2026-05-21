# chiasmus_map tool — Codebase map projections for LLM consumption
require "mcp"
require "../types"
require "../tool_schemas"
require "../../graph/map"
require "../../graph/extractor"

module Chiasmus
  module MCPServer
    module Tools
      class MapTool
        private def error_response(message : String) : Hash(String, JSON::Any)
          JSON.parse(Types::ErrorResponse.new(message).to_json).as_h
        end

        def invoke(arguments : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
          files = arguments["files"]?.try(&.as_a?.try(&.map(&.as_s)))
          mode = arguments["mode"]?.try(&.as_s?) || "overview"
          path = arguments["path"]?.try(&.as_s?)
          name = arguments["name"]?.try(&.as_s?)
          format = arguments["format"]?.try(&.as_s?) || "markdown"

          return error_response("'files' (non-empty string[]) is required") unless files && !files.empty?

          # Read files and extract graph
          source_files = files.compact.map { |p| Graph::SourceFile.new(path: p, content: File.read(p)) }
          graph = Graph::Extractor.extract_graph(source_files)

          map = case mode
                when "file"
                  return error_response("'path' required for file mode") unless path
                  Graph::CodebaseMap.build_file_detail(graph, path)
                when "symbol"
                  return error_response("'name' required for symbol mode") unless name
                  Graph::CodebaseMap.build_symbol_detail(graph, name)
                else
                  Graph::CodebaseMap.build_overview(graph)
                end

          unless map
            return error_response("No result found for #{mode == "file" ? path : name}")
          end

          rendered = Graph::CodebaseMap.render_map(map, format)
          {"content" => JSON::Any.new(rendered)}
        rescue ex
          error_response(ex.message || ex.class.name)
        end

        def self.tool_name : String
          "chiasmus_map"
        end

        def self.tool_description : String
          <<-DESC
          Build a compact codebase map from extracted call graphs. Returns an
          LLM-friendly projection to minimise redundant file reads.

          MODES:
            overview (default) — repo outline: dir tree, per-file headlines, token estimates
            file              — single file: exports, imports, all symbols
            symbol            — symbol by name: definitions, callers, callees

          FORMAT: "markdown" (default) or "json"
          DESC
        end

        def self.input_schema : MCP::Protocol::Tool::Input
          ToolSchemas::ToolInputSchema.new(
            properties: {
              "files" => ToolSchemas::Common.files_property,
              "mode"  => {
                "type"        => JSON::Any.new("string"),
                "description" => JSON::Any.new("Map mode: overview, file, or symbol (default: overview)"),
              },
              "path" => {
                "type"        => JSON::Any.new("string"),
                "description" => JSON::Any.new("File path (required for file mode)"),
              },
              "name" => {
                "type"        => JSON::Any.new("string"),
                "description" => JSON::Any.new("Symbol name (required for symbol mode)"),
              },
              "format" => {
                "type"        => JSON::Any.new("string"),
                "description" => JSON::Any.new("Output format: markdown (default) or json"),
              },
            },
            required: ["files"]
          ).to_mcp_input
        end
      end
    end
  end
end
