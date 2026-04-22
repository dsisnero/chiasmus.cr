# chiasmus_learn tool - Extract reusable template from verified solution
require "mcp"
require "../types"
require "../tool_schemas"

module Chiasmus
  module MCPServer
    module Tools
      class LearnTool
        def invoke(arguments : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
          solver = arguments["solver"]?.try(&.as_s?)
          spec = arguments["spec"]?.try(&.as_s?)
          problem = arguments["problem"]?.try(&.as_s?)

          return json_hash(Types::ErrorResponse.new("Missing required parameters: solver, spec, and problem")) unless solver && spec && problem

          solver_type = case solver
                        when "z3"     then Solvers::SolverType::Z3
                        when "prolog" then Solvers::SolverType::Prolog
                        else
                          return json_hash(Types::ErrorResponse.new("Unknown solver: #{solver}"))
                        end

          learner = MCPServer.current_skill_learner
          return json_hash(Types::ErrorResponse.new("LLM not available. chiasmus_learn requires an LLM for template extraction.")) unless learner

          template = learner.extract_template(solver_type, spec, problem)
          return json_hash(Types::ErrorResponse.new("Template rejected or could not be extracted")) unless template
          learner.check_promotions

          {
            "status"   => JSON::Any.new("success"),
            "template" => JSON::Any.new(template.name),
            "message"  => JSON::Any.new("Template extracted and added to skill library as candidate"),
          }
        rescue ex
          json_hash(Types::ErrorResponse.new(ex.message || ex.class.name))
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

        private def json_hash(response : Types::Response) : Hash(String, JSON::Any)
          JSON.parse(response.to_json).as_h
        end
      end
    end
  end
end
