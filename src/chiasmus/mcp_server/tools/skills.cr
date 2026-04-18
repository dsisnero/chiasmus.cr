# chiasmus_skills tool - List and search skill templates
require "mcp"
require "../types"

module Chiasmus
  module MCPServer
    module Tools
      class SkillsTool
        def invoke(arguments : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
          name = arguments["name"]?.try(&.as_s?)
          query = arguments["query"]?.try(&.as_s?)
          domain = arguments["domain"]?.try(&.as_s?)
          solver = arguments["solver"]?.try(&.as_s?)
          limit = arguments["limit"]?.try(&.as_i?) || 10

          server = MCPServer::Server.instance rescue nil
          return Types::ErrorResponse.new("Server not available").to_json.as_h unless server

          library = server.skill_library

          if name
            # Get template by exact name
            template = library.get(name)
            return Types::ErrorResponse.new("Template '#{name}' not found").to_json.as_h unless template

            suggestions = [] of String # TODO: Implement get_related

            response = Types::SkillsResponse.new(
              templates: [Types.template_to_json(template)],
              suggestions: suggestions
            )
          else
            # Search templates
            search_options = Skills::SearchOptions.new(
              domain: domain,
              solver: solver ? parse_solver_type(solver) : nil,
              limit: limit
            )

            results = library.search(query || "", search_options)

            response = Types::SkillsResponse.new(
              templates: results.map { |r| Types.skill_search_result_to_json(r).template }
            )
          end

          response.to_json.as_h
        rescue ex
          Types::ErrorResponse.new(ex.message || ex.class.name).to_json.as_h
        end

        def self.tool_name : String
          "chiasmus_skills"
        end

        def self.tool_description : String
          <<-DESC
          List and search formalization skill templates.

          Without name or query → lists all templates (starter + learned).
          With name → returns exact template + related suggestions.
          With query → BM25 search over signatures + domains.
          Filter by domain or solver type.
          DESC
        end

        def self.input_schema : MCP::Protocol::Tool::Input
          MCP::Protocol::Tool::Input.new(
            properties: {
              "name" => JSON::Any.new({
                "type"        => JSON::Any.new("string"),
                "description" => JSON::Any.new("Exact template name to retrieve"),
              }),
              "query" => JSON::Any.new({
                "type"        => JSON::Any.new("string"),
                "description" => JSON::Any.new("Search query (BM25 over signatures + domains)"),
              }),
              "domain" => JSON::Any.new({
                "type"        => JSON::Any.new("string"),
                "description" => JSON::Any.new("Filter by domain (authorization, configuration, dependency, validation, rules, analysis)"),
              }),
              "solver" => JSON::Any.new({
                "type"        => JSON::Any.new("string"),
                "enum"        => JSON::Any.new(["z3", "prolog"]),
                "description" => JSON::Any.new("Filter by solver type"),
              }),
              "limit" => JSON::Any.new({
                "type"        => JSON::Any.new("integer"),
                "description" => JSON::Any.new("Maximum number of results (default: 10)"),
              }),
            }
          )
        end

        private def parse_solver_type(solver_str : String) : Solvers::SolverType?
          case solver_str.downcase
          when "z3"
            Solvers::SolverType::Z3
          when "prolog"
            Solvers::SolverType::Prolog
          else
            nil
          end
        end
      end
    end
  end
end
