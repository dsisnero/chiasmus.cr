# chiasmus_map tool — Codebase map projections for LLM consumption
require "mcp"
require "../types"
require "../tool_schemas"
require "./source_paths"
require "./indexed_graph_loader"
require "../../graph/map"
require "../../graph/extractor"
require "../../graph/parallel_io"
require "tracing"

module Chiasmus
  module MCPServer
    module Tools
      class MapTool
        VALID_MODES   = ["overview", "file", "symbol"]
        VALID_FORMATS = ["markdown", "json"]

        def initialize(@project_index : Index::ProjectIndex? = nil)
        end

        # ameba:disable Metrics/CyclomaticComplexity
        def invoke(arguments : Hash(String, JSON::Any)) : Types::Response
          args = Types::MapInput.from_json(arguments.to_json)

          return Types::ErrorResponse.new("'files' (non-empty string[]) is required") if args.files.empty?
          return Types::ErrorResponse.new("Unknown mode: #{args.mode}. Use 'overview', 'file', or 'symbol'.") unless VALID_MODES.includes?(args.mode)
          return Types::ErrorResponse.new("Unknown format: #{args.format}. Use 'markdown' or 'json'.") unless VALID_FORMATS.includes?(args.format)
          return Types::ErrorResponse.new("mode='file' requires 'path' (absolute file path)") if args.mode == "file" && args.path.nil?
          return Types::ErrorResponse.new("mode='symbol' requires 'name' (symbol identifier)") if args.mode == "symbol" && args.name.nil?

          paths = SourcePaths.normalize_file_inputs!(args.files)
          graph = load_graph(paths, args.cache || Graph::GraphCache.default_cache_dir) || return Types::ErrorResponse.new("Unable to index all requested files")

          map = case args.mode
                when "file"
                  Graph::CodebaseMap.build_file_detail(graph, args.path.not_nil!)
                when "symbol"
                  Graph::CodebaseMap.build_symbol_detail(graph, args.name.not_nil!)
                else
                  Graph::CodebaseMap.build_overview(
                    graph,
                    max_exports: args.max_exports || Graph::DEFAULT_MAX_EXPORTS,
                    include_patterns: args.include_patterns,
                  )
                end

          unless map
            return Types::ErrorResponse.new("No result found for #{args.mode == "file" ? args.path : args.name}")
          end

          rendered = Graph::CodebaseMap.render_map(map, args.format)
          return Types::MapJSONResponse.new(JSON.parse(rendered)) if args.format == "json"

          Types::MapResponse.new(content: rendered)
        rescue ex
          Types::ErrorResponse.new(ex.message || ex.class.name)
        end

        # ameba:enable Metrics/CyclomaticComplexity

        private def load_graph(paths : Array(String), cache_dir : String?) : Graph::CodeGraph?
          IndexedGraphLoader.load_graph(paths, cache_dir, @project_index, "chiasmus.map.cache")
        end

        def self.tool_name : String
          "chiasmus_map"
        end

        def self.tool_description : String
          <<-DESC
          Build a compact codebase map from extracted call graphs. Returns an
          LLM-friendly projection to minimise redundant file reads.

          Dedicated walkers: Crystal, TypeScript, JavaScript, Python, Go, Rust, Java,
          C#, C++, C, Kotlin, Scala, Dart, PHP, Perl, Bash, Protobuf, Clojure.
          Generic tree-sitter fallback for 35+ additional languages.
          Extraction runs concurrently across files.

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
              "files"       => ToolSchemas::Common.files_property.to_json_schema,
              "mode"        => ToolSchemas::SchemaProperty.new("string", "Map mode (default: overview)", VALID_MODES).to_json_schema,
              "path"        => ToolSchemas::SchemaProperty.new("string", "File path (required for file mode)").to_json_schema,
              "name"        => ToolSchemas::SchemaProperty.new("string", "Symbol name (required for symbol mode)").to_json_schema,
              "format"      => ToolSchemas::SchemaProperty.new("string", "Output format (default: markdown)", VALID_FORMATS).to_json_schema,
              "include"     => ToolSchemas::ArraySchemaProperty.new("Glob patterns to filter files in overview mode").to_json_schema,
              "max_exports" => ToolSchemas::SchemaProperty.new("number", "Max exports per file in overview mode (clamped to zero or above)").to_json_schema,
            }.transform_values { |v| JSON::Any.new(v) },
            required: ["files"]
          ).to_mcp_input
        end

        def self.output_schema : MCP::Protocol::Tool::Input
          MCP::Protocol::Tool::Input.new(
            properties: JSON.parse(%({"status":{"type":"string"},"content":{"type":"string"}})).as_h
          )
        end
      end
    end
  end
end
