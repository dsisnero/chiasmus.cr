# chiasmus_formalize tool - Find best template for problem
require "mcp"
require "../types"

module Chiasmus
  module MCPServer
    module Tools
      class FormalizeTool
        def invoke(arguments : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
          problem = arguments["problem"]?.try(&.as_s?)

          if problem.nil? || problem.empty?
            return Types::ErrorResponse.new("The 'problem' parameter (string) is required").to_json.as_h
          end

          server = MCPServer::Server.instance rescue nil
          return Types::ErrorResponse.new("Server not available").to_json.as_h unless server

          formalization_engine = server.formalization_engine
          return Types::ErrorResponse.new("Formalization engine not available").to_json.as_h unless formalization_engine

          # Formalize the problem
          result = formalization_engine.formalize(problem)

          suggestions = [] of String

          response = Types::FormalizeResponse.new(
            template: result.template.name,
            solver: result.template.solver.to_s.downcase,
            domain: result.template.domain,
            instructions: result.instructions,
            suggestions: suggestions
          )

          response.to_json.as_h
        rescue ex
          Types::ErrorResponse.new(ex.message || ex.class.name).to_json.as_h
        end

        def self.tool_name : String
          "chiasmus_formalize"
        end

        def self.tool_description : String
          <<-DESC
          Find best template for problem → return skeleton + slot-filling instructions + tips.

          Guided workflow:
            1. chiasmus_formalize → get template + slots + tips
            2. Fill slots using your context
            3. chiasmus_verify → verified result
          DESC
        end

        def self.input_schema : MCP::Protocol::Tool::Input
          MCP::Protocol::Tool::Input.new(
            properties: {
              "problem" => JSON::Any.new({
                "type"        => JSON::Any.new("string"),
                "description" => JSON::Any.new("Natural language description of the problem to formalize"),
              }),
            },
            required: ["problem"]
          )
        end
      end
    end
  end
end
