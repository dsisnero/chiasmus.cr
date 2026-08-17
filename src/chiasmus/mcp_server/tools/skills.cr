# chiasmus_skills tool - List and search skill templates
require "mcp"
require "../types"

module Chiasmus
  module MCPServer
    module Tools
      class SkillsTool
        def invoke(arguments : Hash(String, JSON::Any)) : Types::Response
          args = Types::SkillsInput.from_json(arguments.to_json)

          server = MCPServer.current_server
          return Types::ErrorResponse.new("Server not available") unless server

          library = server.skill_library

          if args.name
            name = args.name.not_nil!
            template = library.get(name)
            return Types::ErrorResponse.new("Template '#{name}' not found") unless template

            related = library.get_related(name).map do |related_template|
              JSON.parse({
                "name"   => related_template.name,
                "reason" => related_template.reason,
              }.to_json)
            end

            Types::SkillLookupResponse.new(
              template: Types.template_to_json(template.template),
              metadata: Types.skill_metadata_to_json(template.metadata),
              related: related
            )
          elsif query = args.query
            search_options = Skills::SearchOptions.new(
              domain: args.domain,
              solver: args.solver ? parse_solver_type(args.solver.not_nil!) : nil,
              limit: args.limit
            )

            results = library.search(query, search_options)

            Types::SkillsResponse.new(
              templates: results.map { |search_result| Types.skill_search_result_to_json(search_result).template },
              search_results: results.map { |search_result| Types.skill_search_result_to_json(search_result) }
            )
          else
            templates = library.list
            templates = templates.select { |item| item.template.domain == args.domain } if args.domain
            if solver_type = args.solver.try { |solver| parse_solver_type(solver) }
              templates = templates.select { |item| item.template.solver == solver_type }
            end

            Types::SkillsResponse.new(
              templates: templates.map { |item| Types.template_to_json(item.template) },
              collection: templates.map { |item| Types.skill_with_metadata_to_json(item) }
            )
          end
        rescue ex
          Types::ErrorResponse.new(ex.message || ex.class.name)
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
                "enum"        => JSON::Any.new(["z3", "prolog"].map { |v| JSON::Any.new(v) }),
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

        def self.output_schema : MCP::Protocol::Tool::Input
          MCP::Protocol::Tool::Input.new(
            properties: JSON.parse(%({
              "status":{"type":"string"},
              "templates":{"type":"array"},
              "template":{"type":"object"},
              "metadata":{"type":"object"},
              "related":{"type":"array"}
            })).as_h
          )
        end
      end
    end
  end
end
