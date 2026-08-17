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

          server = MCPServer.refresh_with_llm_if_available(MCPServer.current_server)
          return Types::ErrorResponse.new("Server not available") unless server

          async_result = server.solve_async(args.problem).receive
          if error = async_result.error
            return Types::ErrorResponse.new(error)
          end

          result = async_result.value
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
              solver_result = attempt.result
              status = solver_result.try(&.status) || "error"
              error = solver_result.is_a?(Solvers::ErrorResult) ? solver_result.error : attempt.error
              Types::SolveHistoryEntryJSON.new(attempt.round, status, error)
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

          Needs ANTHROPIC_API_KEY | DEEPSEEK_API_KEY | OPENAI_API_KEY. Without key → falls back to chiasmus_formalize.
          Returns: solver result + template used + correction history. NOTE: `converged: true` means the correction loop reached a non-error solver result — it does NOT mean the property holds. Read `result.status` (sat / unsat / unknown) for the actual verdict; an `unsat` ("no counterexample in this model") is not a proof.
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

        private def fallback_to_formalize(library : Skills::Library, problem : String) : Types::Response
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

          Types::SolveFallbackResponse.new(
            template: formalize_result.template.name,
            solver: formalize_result.template.solver.to_s.downcase,
            instructions: formalize_result.instructions,
            message: "No LLM API key configured. Returning template instructions instead. Fill the slots and use chiasmus_verify."
          )
        end

        def self.output_schema : MCP::Protocol::Tool::Input
          MCP::Protocol::Tool::Input.new(
            properties: JSON.parse(%({"status":{"type":"string"},"result":{"type":"object"},"converged":{"type":"boolean"},"rounds":{"type":"integer"},"templateUsed":{"type":"string"},"answers":{"type":"array"},"history":{"type":"array"},"template":{"type":"string"},"solver":{"type":"string"},"instructions":{"type":"string"}})).as_h
          )
        end
      end
    end
  end
end
