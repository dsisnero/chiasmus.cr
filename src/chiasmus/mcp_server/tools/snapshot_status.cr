# chiasmus_snapshot_status tool - Poll durable graph snapshot receipts
require "mcp"
require "../types"
require "../tool_schemas"
require "../../graph/cache"

module Chiasmus
  module MCPServer
    module Tools
      class SnapshotStatusTool
        def invoke(arguments : Hash(String, JSON::Any)) : Types::Response
          args = Types::SnapshotStatusInput.from_json(arguments.to_json)
          cache_dir = args.cache.try(&.cache_dir) || Graph::GraphCache.default_cache_dir
          repo_key = args.cache.try(&.repo_key)
          receipt = Graph::GraphCache.snapshot_status(args.snapshot, cache_dir, repo_key: repo_key)
          return Types::ErrorResponse.new("No snapshot receipt found for: #{args.snapshot}") unless receipt

          Types::SnapshotStatusResponse.new(
            snapshot: receipt.snapshot,
            state: receipt.state,
            updated_at: receipt.updated_at,
            error: receipt.error,
          )
        rescue ex
          Types::ErrorResponse.new(ex.message || ex.class.name)
        end

        def self.tool_name : String
          "chiasmus_snapshot_status"
        end

        def self.tool_description : String
          "Poll the durable lifecycle receipt for a named graph snapshot after a lost, cancelled, or timed-out save request."
        end

        def self.input_schema : MCP::Protocol::Tool::Input
          ToolSchemas::ToolInputSchema.new(
            properties: {
              "snapshot" => ToolSchemas::SchemaProperty.new("string", "Snapshot name to inspect"),
              "cache"    => ToolSchemas::SchemaProperty.new("object", "Cache options: {cache_dir, repo_key}"),
            },
            required: ["snapshot"]
          ).to_mcp_input
        end

        def self.output_schema : MCP::Protocol::Tool::Input
          MCP::Protocol::Tool::Input.new(
            properties: JSON.parse(%({"status":{"type":"string"},"snapshot":{"type":"string"},"state":{"type":"string"},"updated_at":{"type":"integer"},"error":{"type":"string"}})).as_h
          )
        end
      end
    end
  end
end
