# chiasmus_map tool — Codebase map projections for LLM consumption
require "mcp"
require "../types"
require "../tool_schemas"
require "../../graph/map"
require "../../graph/extractor"
require "../../graph/parallel_io"

module Chiasmus
  module MCPServer
    module Tools
      class MapTool
        def invoke(arguments : Hash(String, JSON::Any)) : Types::Response
          args = Types::MapInput.from_json(arguments.to_json)

          return Types::ErrorResponse.new("'files' (non-empty string[]) is required") if args.files.empty?

          source_files = Graph::FileIO.read_source_files_or_raise(args.files)
          graph = Graph::Extractor.extract_graph(source_files, cache_dir: args.cache)

          map = case args.mode
                when "file"
                  return Types::ErrorResponse.new("'path' required for file mode") unless args.path
                  Graph::CodebaseMap.build_file_detail(graph, args.path.not_nil!)
                when "symbol"
                  return Types::ErrorResponse.new("'name' required for symbol mode") unless args.name
                  Graph::CodebaseMap.build_symbol_detail(graph, args.name.not_nil!)
                else
                  Graph::CodebaseMap.build_overview(graph)
                end

          unless map
            return Types::ErrorResponse.new("No result found for #{args.mode == "file" ? args.path : args.name}")
          end

          rendered = Graph::CodebaseMap.render_map(map, args.format)
          Types::MapResponse.new(content: rendered)
        rescue ex
          Types::ErrorResponse.new(ex.message || ex.class.name)
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
              "files"  => ToolSchemas::Common.files_property.to_json_schema,
              "mode"   => ToolSchemas::SchemaProperty.new("string", "Map mode: overview, file, or symbol (default: overview)").to_json_schema,
              "path"   => ToolSchemas::SchemaProperty.new("string", "File path (required for file mode)").to_json_schema,
              "name"   => ToolSchemas::SchemaProperty.new("string", "Symbol name (required for symbol mode)").to_json_schema,
              "format" => ToolSchemas::SchemaProperty.new("string", "Output format: markdown (default) or json").to_json_schema,
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
