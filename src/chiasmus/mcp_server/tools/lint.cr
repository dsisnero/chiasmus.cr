# chiasmus_lint tool - Fast structural validation of formal spec
require "mcp"
require "../types"
require "../tool_schemas"

module Chiasmus
  module MCPServer
    module Tools
      class LintTool
        def invoke(arguments : Hash(String, JSON::Any)) : Types::Response
          args = Types::LintInput.from_json(arguments.to_json)

          solver_type = case args.solver
                        when "z3"     then Solvers::SolverType::Z3
                        when "prolog" then Solvers::SolverType::Prolog
                        else
                          return Types::ErrorResponse.new("Unknown solver: #{args.solver}")
                        end

          lint_result = Formalize.lint_spec(args.input, solver_type)

          Types::LintResponse.new(
            spec: lint_result.spec,
            fixes: lint_result.fixes,
            errors: lint_result.errors
          )
        rescue ex
          Types::ErrorResponse.new(ex.message || ex.class.name)
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
      end
    end
  end
end
