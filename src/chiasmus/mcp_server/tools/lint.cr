# chiasmus_lint tool - Fast structural validation of formal spec
require "mcp"
require "../types"
require "../tool_schemas"

module Chiasmus
  module MCPServer
    module Tools
      class LintTool
        def invoke(arguments : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
          solver = arguments["solver"]?.try(&.as_s?)
          input = arguments["input"]?.try(&.as_s?)

          return json_hash(Types::ErrorResponse.new("Missing required parameters: solver and input")) unless solver && input

          solver_type = case solver
                        when "z3"     then Solvers::SolverType::Z3
                        when "prolog" then Solvers::SolverType::Prolog
                        else
                          return json_hash(Types::ErrorResponse.new("Unknown solver: #{solver}"))
                        end

          # Use the formalize module's lint_spec function
          lint_result = Formalize.lint_spec(input, solver_type)

          # Convert to JSON response
          {
            "status" => JSON::Any.new("success"),
            "spec"   => JSON::Any.new(lint_result.spec),
            "fixes"  => JSON::Any.new(string_array(lint_result.fixes)),
            "errors" => JSON::Any.new(string_array(lint_result.errors)),
          }
        rescue ex
          json_hash(Types::ErrorResponse.new(ex.message || ex.class.name))
        end

        def self.tool_name : String
          "chiasmus_lint"
        end

        def self.tool_description : String
          <<-DESC
          Fast structural validation of formal spec without running solver.

          Auto-fixes: markdown fences, (check-sat)/(get-model), (set-logic).
          Checks: balanced parens, unfilled {{SLOT:}} markers, missing periods (Prolog).
          Returns cleaned spec + fixes applied + remaining errors.
          DESC
        end

        def self.input_schema : MCP::Protocol::Tool::Input
          ToolSchemas::ToolInputSchema.new(
            properties: {
              "solver" => ToolSchemas::Common.solver_property,
              "input"  => ToolSchemas::Common.input_property,
            },
            required: ["solver", "input"]
          ).to_mcp_input
        end

        private def json_hash(response : Types::Response) : Hash(String, JSON::Any)
          JSON.parse(response.to_json).as_h
        end

        private def string_array(values : Array(String)) : Array(JSON::Any)
          values.map { |value| JSON::Any.new(value) }
        end
      end
    end
  end
end
