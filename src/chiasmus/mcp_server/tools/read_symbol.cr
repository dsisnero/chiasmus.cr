require "mcp"
require "../types"
require "../tool_schemas"
require "./source_paths"
require "./indexed_graph_loader"

module Chiasmus
  module MCPServer
    module Tools
      class ReadSymbolTool
        def initialize(@project_index : Index::ProjectIndex? = nil)
        end

        def invoke(arguments : Hash(String, JSON::Any)) : Types::Response
          args = Types::ReadSymbolInput.from_json(arguments.to_json)

          return Types::ErrorResponse.new("'files' (non-empty string[]) is required") if args.files.empty?
          return Types::ErrorResponse.new("Either 'qualified_name' or 'name' is required") if args.qualified_name.nil? && args.name.nil?

          paths = SourcePaths.normalize_file_inputs!(args.files)
          graph = IndexedGraphLoader.load_graph(paths, Graph::GraphCache.default_cache_dir, @project_index, "chiasmus.read_symbol.cache") ||
                  return Types::ErrorResponse.new("Unable to index all requested files")

          file_filter = args.file.try { |path| File.expand_path(path) }
          matches = graph.defines.select do |define|
            next false if file_filter && define.file != file_filter

            if qualified_name = args.qualified_name
              define.qualified_name == qualified_name || (define.qualified_name.nil? && define.name == qualified_name)
            elsif name = args.name
              define.name == name
            else
              false
            end
          end

          return Types::ErrorResponse.new("No matching symbol found") if matches.empty?
          if matches.size > 1
            return Types::ErrorResponse.new("Ambiguous symbol match. Provide 'file' or 'qualified_name' to disambiguate.")
          end

          define = matches.first
          source = File.read(define.file)

          Types::ReadSymbolResponse.new(
            name: define.name,
            qualified_name: define.qualified_name,
            file: define.file,
            kind: define.kind.to_s.downcase,
            signature: define.signature,
            start_line: define.span.start_line,
            end_line: define.span.end_line,
            content: slice_symbol_content(source, define.span),
          )
        rescue ex
          Types::ErrorResponse.new(ex.message || ex.class.name)
        end

        private def slice_symbol_content(source : String, span : Graph::Span) : String
          if span.end_byte > span.start_byte && span.end_byte <= source.bytesize
            source.byte_slice(span.start_byte, span.end_byte - span.start_byte) || ""
          else
            lines = source.lines
            start_line = Math.max(1, span.start_line)
            end_line = Math.max(start_line, span.end_line)
            lines[(start_line - 1)...Math.min(lines.size, end_line)].join
          end
        end

        def self.tool_name : String
          "chiasmus_read_symbol"
        end

        def self.tool_description : String
          <<-DESC
          Read the source for one symbol after you have identified it via
          chiasmus_search, chiasmus_map, or chiasmus_graph. Provide 'files'
          plus either 'qualified_name' or 'name'. If 'name' is ambiguous,
          also provide 'file'. Returns one symbol's file path, kind,
          signature, start/end lines, and sliced source content.
          DESC
        end

        def self.input_schema : MCP::Protocol::Tool::Input
          ToolSchemas::ToolInputSchema.new(
            properties: {
              "files"          => ToolSchemas::Common.files_property.to_json_schema,
              "name"           => ToolSchemas::SchemaProperty.new("string", "Unqualified symbol name to resolve within the indexed files. Use together with 'file' when the name is not unique.").to_json_schema,
              "qualified_name" => ToolSchemas::SchemaProperty.new("string", "Fully qualified symbol name, for example 'Sample.call'. Preferred when available because it avoids ambiguity.").to_json_schema,
              "file"           => ToolSchemas::SchemaProperty.new("string", "Absolute file path used to disambiguate 'name' matches and force the lookup to one file.").to_json_schema,
            }.transform_values { |value| JSON::Any.new(value) },
            required: ["files"]
          ).to_mcp_input
        end

        def self.output_schema : MCP::Protocol::Tool::Input
          MCP::Protocol::Tool::Input.new(
            properties: JSON.parse(%({"status":{"type":"string"},"name":{"type":"string"},"qualified_name":{"type":"string"},"file":{"type":"string"},"kind":{"type":"string"},"signature":{"type":"string"},"start_line":{"type":"number"},"end_line":{"type":"number"},"content":{"type":"string"}})).as_h
          )
        end
      end
    end
  end
end
