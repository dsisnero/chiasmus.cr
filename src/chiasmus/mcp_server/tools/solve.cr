# chiasmus_solve tool - End-to-end problem solving
require "mcp"
require "../types"

module Chiasmus
  module MCPServer
    module Tools
      class SolveTool
        def invoke(arguments : Hash(String, JSON::Any)) : Types::Response
          args = Types::SolveInput.from_json(arguments.to_json)

          if args.problem.empty?
            return Types::ErrorResponse.new("The 'problem' parameter (string) is required")
          end

          server = MCPServer.current_server
          return Types::ErrorResponse.new("Server not available") unless server

          result = server.solve(args.problem)
          unless result
            return fallback_to_formalize(server.skill_library, args.problem)
          end

          Types::SolveResponse.new(
            result: Types.solver_result_to_json(result.result),
            converged: result.converged,
            rounds: result.rounds,
            template_used: result.template_used,
            answers: result.answers.map { |answer| Types::PrologAnswerJSON.new(answer.bindings, answer.formatted) },
            history: result.history.map { |attempt|
              Types::CorrectionAttemptJSON.new(
                Types.solver_input_to_json(attempt.input),
                attempt.result.try { |solver_result| Types.solver_result_to_json(solver_result) },
                attempt.error
              )
            }
          )
        rescue ex
          Types::ErrorResponse.new(ex.message || ex.class.name)
        end

        def self.tool_name : String
          "chiasmus_solve"
        end

        def self.tool_description : String
          <<-DESC
          End-to-end: select template → fill slots → lint → verify → correction loop.

          Needs OPENAI_API_KEY. Without key → falls back to chiasmus_formalize.
          Returns: verified result + template used + correction history.
          DESC
        end

        def self.input_schema : MCP::Protocol::Tool::Input
          MCP::Protocol::Tool::Input.new(
            properties: {
              "problem" => JSON::Any.new({
                "type"        => JSON::Any.new("string"),
                "description" => JSON::Any.new("Natural language description of the problem to solve"),
              }),
            },
            required: ["problem"]
          )
        end

        private def fallback_to_formalize(library : Skills::Library, problem : String) : Types::SolveResponse
          engine = Formalize::Engine.new(library, LLM::MockAdapter.create_agent)
          formalize_result = engine.formalize(problem)
          unless formalize_result
            return Types::SolveResponse.new(
              result: Types::SolverResultJSON.new(status: "error", error: "No matching template found"),
              converged: false,
              rounds: 0,
              fallback: true,
              message: "No matching template found — skill library is empty"
            )
          end

          Types::SolveResponse.new(
            result: Types::SolverResultJSON.new(status: "formalized"),
            converged: false,
            rounds: 0,
            template_used: formalize_result.template.name,
            fallback: true,
            message: "No LLM API key configured. Returning template instructions instead. Fill the slots and use chiasmus_verify."
          )
        end
      end
    end
  end
end
