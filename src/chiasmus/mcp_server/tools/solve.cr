# chiasmus_solve tool - End-to-end problem solving
require "mcp"
require "../types"

module Chiasmus
  module MCPServer
    module Tools
      class SolveTool
        def invoke(arguments : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
          problem = arguments["problem"]?.try(&.as_s?)

          if problem.nil? || problem.empty?
            return Types::ErrorResponse.new("The 'problem' parameter (string) is required").to_json.as_h
          end

          server = MCPServer::Server.instance rescue nil
          return Types::ErrorResponse.new("Server not available").to_json.as_h unless server

          formalization_engine = server.formalization_engine

          # If no LLM configured, fall back to formalize
          unless formalization_engine
            return fallback_to_formalize(server.skill_library, problem)
          end

          # Solve the problem end-to-end
          result = formalization_engine.solve(problem)

          response = Types::SolveResponse.new(
            result: Types.solver_result_to_json(result.result),
            converged: result.converged,
            rounds: result.rounds,
            template_used: result.template_used,
            answers: result.answers.map { |answer| Types::PrologAnswerJSON.new(answer.bindings, answer.formatted) },
            history: result.history.map { |attempt|
              Types::CorrectionAttemptJSON.new(
                Types.solver_input_to_json(attempt.input),
                attempt.result ? Types.solver_result_to_json(attempt.result) : nil,
                attempt.error
              )
            }
          )

          response.to_json.as_h
        rescue ex
          Types::ErrorResponse.new(ex.message || ex.class.name).to_json.as_h
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

        private def fallback_to_formalize(library : Skills::Library, problem : String) : Hash(String, JSON::Any)
          # Create a dummy engine for formalize only
          dummy_agent = LLM::MockAdapter.new
          dummy_agent.add_response("formalize", "Mock response")

          engine = Formalize::Engine.new(library, dummy_agent)
          formalize_result = engine.formalize(problem)

          # Create a formalize response instead of solve response
          response = Types::FormalizeResponse.new(
            template: formalize_result.template.name,
            solver: formalize_result.template.solver.to_s.downcase,
            domain: formalize_result.template.domain,
            instructions: formalize_result.instructions,
            suggestions: [] of String
          )

          # Wrap in a hash with fallback flag
          json = response.to_json.as_h
          json["fallback"] = JSON::Any.new(true)
          json["message"] = JSON::Any.new("No LLM API key configured. Returning template instructions instead. Fill the slots and use chiasmus_verify.")
          json
        end
      end
    end
  end
end
