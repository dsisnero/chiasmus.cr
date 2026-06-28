# chiasmus_learn tool - Extract reusable template from verified solution
require "mcp"
require "../types"
require "../tool_schemas"

module Chiasmus
  module MCPServer
    module Tools
      class LearnTool
        def invoke(arguments : Hash(String, JSON::Any)) : Types::Response
          args = Types::LearnInput.from_json(arguments.to_json)

          return Types::ErrorResponse.new("Missing required parameters: solver, spec, and problem") unless args.solver && args.spec && args.problem

          solver_type = case args.solver
                        when "z3"     then Solvers::SolverType::Z3
                        when "prolog" then Solvers::SolverType::Prolog
                        else
                          return Types::ErrorResponse.new("Unknown solver: #{args.solver}")
                        end

          server = MCPServer.refresh_with_llm_if_available(MCPServer.current_server)
          learner = server.try(&.skill_learner)
          return Types::ErrorResponse.new("LLM not available. chiasmus_learn requires an LLM for template extraction.") unless learner

          async_result = learner.learn_async(solver_type, args.spec, args.problem).receive
          if error = async_result.error
            return Types::ErrorResponse.new(error)
          end

          template = async_result.template
          return Types::ErrorResponse.new("Template rejected or could not be extracted") unless template

          Types::LearnResponse.new(
            template: template.name,
            message: "Template extracted and added to skill library as candidate"
          )
        rescue ex
          Types::ErrorResponse.new(ex.message || ex.class.name)
        end

        def self.tool_name : String
          "chiasmus_learn"
        end

        def self.tool_description : String
          <<-DESC
          Extract reusable template from verified solution → add to skill library.

          Generalizes concrete spec into parameterized template. Stored as candidate → promoted after 3+ successful reuses.
          Needs API key. Flow: chiasmus_verify → chiasmus_learn → template appears in chiasmus_skills.
          DESC
        end

        def self.input_schema : MCP::Protocol::Tool::Input
          ToolSchemas::ToolInputSchema.new(
            properties: {
              "solver"  => ToolSchemas::Common.solver_property,
              "spec"    => ToolSchemas::Common.spec_property,
              "problem" => ToolSchemas::Common.problem_property,
            },
            required: ["solver", "spec", "problem"]
          ).to_mcp_input
        end

        def self.output_schema : MCP::Protocol::Tool::Input
          MCP::Protocol::Tool::Input.new(
            properties: JSON.parse(%({"status":{"type":"string"},"template":{"type":"string"},"message":{"type":"string"}})).as_h
          )
        end
      end
    end
  end
end
