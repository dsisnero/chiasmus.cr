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
            return json_hash(Types::ErrorResponse.new("The 'problem' parameter (string) is required"))
          end

          server = MCPServer.current_server
          return json_hash(Types::ErrorResponse.new("Server not available")) unless server

          # Formalize the problem
          result = server.formalize(problem)
          return json_hash(Types::ErrorResponse.new("Formalization engine not available")) unless result

          suggestions = server.skill_library.get_related(result.template.name).map do |related|
            JSON.parse({
              "name"   => related.name,
              "reason" => related.reason,
            }.to_json)
          end

          response = Types::FormalizeResponse.new(
            template: result.template.name,
            solver: result.template.solver.to_s.downcase,
            domain: result.template.domain,
            instructions: result.instructions,
            suggestions: suggestions
          )

          json_hash(response)
        rescue ex
          json_hash(Types::ErrorResponse.new(ex.message || ex.class.name))
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

        private def json_hash(response : Types::Response) : Hash(String, JSON::Any)
          JSON.parse(response.to_json).as_h
        end
      end
    end
  end
end
