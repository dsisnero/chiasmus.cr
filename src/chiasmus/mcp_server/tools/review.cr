# chiasmus_review tool — Generate code review plan recipe
require "mcp"
require "../types"
require "../tool_schemas"
require "../../review"

module Chiasmus
  module MCPServer
    module Tools
      class ReviewTool
        def invoke(arguments : Hash(String, JSON::Any)) : Types::Response
          if error = self.class.validate_arguments(arguments)
            return Types::ErrorResponse.new(error)
          end

          args = Types::ReviewInput.from_json(arguments.to_json)

          begin
            plan = Review.build_plan(args.files, args.focus, args.entry_points, args.delta_against)
            review_plan_to_response(plan)
          rescue ex : ArgumentError
            Types::ErrorResponse.new(ex.message || "Invalid arguments")
          rescue ex
            Types::ErrorResponse.new(ex.message || ex.class.name)
          end
        end

        private def review_plan_to_response(plan : Review::ReviewPlan) : Types::ReviewResponse
          Types::ReviewResponse.new(
            files: plan.files,
            focus: plan.focus,
            summary: plan.summary,
            phases: plan.phases.map { |phase| review_phase_to_json(phase) },
            suggested_templates: plan.suggested_templates.map { |template| suggested_template_to_json(template) },
            reporting: review_reporting_to_json(plan.reporting)
          )
        end

        # Check raw MCP input before JSON::Serializable or Review.build_plan so
        # malformed callers receive the stable upstream error contract.
        def self.validate_arguments(arguments : Hash(String, JSON::Any)) : String?
          files = arguments["files"]?.try(&.as_a?)
          return "'files' (non-empty string[]) is required" unless files
          return "'files' (non-empty string[]) is required" if files.empty?
          return "'files' must contain only strings" if files.any? { |file| file.as_s?.nil? }

          nil
        end

        private def review_phase_to_json(phase : Review::ReviewPhase) : Types::ReviewPhaseJSON
          Types::ReviewPhaseJSON.new(
            phase: phase.phase,
            goal: phase.goal,
            actions: phase.actions.map { |action|
              Types::ReviewActionJSON.new(
                tool: action.tool,
                args: action.args,
                interpret: action.interpret
              )
            }
          )
        end

        private def suggested_template_to_json(template : Review::SuggestedTemplate) : Types::SuggestedTemplateJSON
          Types::SuggestedTemplateJSON.new(
            template: template.template,
            when: template.when,
            workflow: template.workflow
          )
        end

        private def review_reporting_to_json(reporting : Review::ReviewReporting) : Types::ReviewReportingJSON
          Types::ReviewReportingJSON.new(
            format: reporting.format,
            severity_levels: reporting.severity_levels,
            instructions: reporting.instructions
          )
        end

        def self.tool_name : String
          "chiasmus_review"
        end

        def self.tool_description : String
          <<-DESC
          Generate a structured code review plan. Returns a phased recipe
          with specific chiasmus tools, templates, and interpret guidance.

          Dedicated walkers: Crystal, TypeScript, JavaScript, Python, Go, Rust, Java,
          C#, C++, C, Kotlin, Scala, Dart, PHP, Perl, Bash, Protobuf, Clojure.
          Generic tree-sitter fallback for 35+ additional languages.

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
              "files"         => ToolSchemas::Common.files_property.to_json_schema,
              "focus"         => ToolSchemas::SchemaProperty.new("string", "Review focus: all, quick, architecture, security, correctness").to_json_schema,
              "entry_points"  => ToolSchemas::Common.entry_points_property.to_json_schema,
              "delta_against" => ToolSchemas::SchemaProperty.new("string", "Snapshot name to diff against for PR-scoped review").to_json_schema,
            }.transform_values { |value| JSON::Any.new(value) },
            required: ["files"]
          ).to_mcp_input
        end

        def self.output_schema : MCP::Protocol::Tool::Input
          MCP::Protocol::Tool::Input.new(
            properties: JSON.parse(%({"status":{"type":"string"},"files":{"type":"array"},"focus":{"type":"string"},"summary":{"type":"string"},"phases":{"type":"array"},"suggestedTemplates":{"type":"array"},"reporting":{"type":"object"}})).as_h
          )
        end
      end
    end
  end
end
