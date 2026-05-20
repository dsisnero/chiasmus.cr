# chiasmus_review tool — Generate code review plan recipe
require "mcp"
require "../types"
require "../tool_schemas"
require "../../review"

module Chiasmus
  module MCPServer
    module Tools
      class ReviewTool
        private def error_response(message : String) : Hash(String, JSON::Any)
          JSON.parse(Types::ErrorResponse.new(message).to_json).as_h
        end

        def invoke(arguments : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
          files = arguments["files"]?.try(&.as_a?.try(&.map(&.as_s)))
          focus = arguments["focus"]?.try(&.as_s?)
          entry_points = arguments["entry_points"]?.try(&.as_a?.try(&.map(&.as_s)))
          delta_against = arguments["delta_against"]?.try(&.as_s?)

          return error_response("'files' (non-empty string[]) is required") unless files && !files.empty?

          begin
            plan = Review.build_plan(files, focus, entry_points, delta_against)
            JSON.parse(plan.to_json).as_h
          rescue ex : ArgumentError
            error_response(ex.message || "Invalid arguments")
          rescue ex
            error_response(ex.message || ex.class.name)
          end
        end

        def self.tool_name : String
          "chiasmus_review"
        end

        def self.tool_description : String
          <<-DESC
          Generate a structured code review plan. Returns a phased recipe
          with specific chiasmus tools, templates, and interpret guidance.

          FOCUS MODES:
            quick         — overview + architecture (fastest)
            architecture  — overview + architecture + impact
            security      — overview + taint + resource + authorization
            correctness   — overview + invariants + boundary + impact
            all           — every phase (default)

          DELTA REVIEW:
            Set delta_against=<snapshot> to scope the review to symbols
            changed since that snapshot (requires previous chiasmus_graph
            save_snapshot=<name>). Phase 0 diffs against the snapshot
            and drives subsequent phases' focus.
          DESC
        end

        def self.input_schema : MCP::Protocol::Tool::Input
          ToolSchemas::ToolInputSchema.new(
            properties: {
              "files" => ToolSchemas::Common.files_property,
              "focus" => {
                "type"        => JSON::Any.new("string"),
                "description" => JSON::Any.new("Review focus: all, quick, architecture, security, correctness"),
              },
              "entry_points"  => ToolSchemas::Common.entry_points_property,
              "delta_against" => {
                "type"        => JSON::Any.new("string"),
                "description" => JSON::Any.new("Snapshot name to diff against for PR-scoped review"),
              },
            },
            required: ["files"]
          ).to_mcp_input
        end
      end
    end
  end
end
