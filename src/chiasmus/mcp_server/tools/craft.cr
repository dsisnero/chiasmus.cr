# chiasmus_craft tool - Create a new formalization template
require "mcp"
require "../types"
require "../tool_schemas"

module Chiasmus
  module MCPServer
    module Tools
      class CraftTool
        VALID_DOMAINS = ["authorization", "configuration", "dependency", "validation", "rules", "analysis", "custom"]

        def invoke(arguments : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
          params = extract_params(arguments)
          error = validate_required_params(params)
          return error if error

          solver_type = parse_solver_type(params[:solver])
          return error_response("Unknown solver: #{params[:solver]}") unless solver_type

          domain = params[:domain]
          return invalid_domain_response(domain) unless VALID_DOMAINS.includes?(domain)

          template = build_template(params, solver_type)
          test_failure = verify_template(template, params[:test], params[:test_example])
          return test_failure if test_failure

          Skills::Library.instance.add_template(template)
          success_response(template.name)
        rescue ex
          error_response(ex.message || ex.class.name)
        end

        private def extract_params(arguments : Hash(String, JSON::Any)) : NamedTuple(
          name: String?,
          domain: String?,
          solver: String?,
          signature: String?,
          skeleton: String?,
          slots: Hash(String, JSON::Any)?,
          normalization: Hash(String, JSON::Any)?,
          test: Bool,
          test_example: String?)
          {
            name:          arguments["name"]?.try(&.as_s?),
            domain:        arguments["domain"]?.try(&.as_s?),
            solver:        arguments["solver"]?.try(&.as_s?),
            signature:     arguments["signature"]?.try(&.as_s?),
            skeleton:      arguments["skeleton"]?.try(&.as_s?),
            slots:         arguments["slots"]?.try(&.as_h?),
            normalization: arguments["normalization"]?.try(&.as_h?),
            test:          arguments["test"]?.try(&.as_bool?) || false,
            test_example:  arguments["test_example"]?.try(&.as_s?),
          }
        end

        private def validate_required_params(params) : Hash(String, JSON::Any)?
          return if params[:name] && params[:domain] && params[:solver] && params[:signature] && params[:skeleton] && params[:slots]

          error_response("Missing required parameters: name, domain, solver, signature, skeleton, slots")
        end

        private def parse_solver_type(solver : String?) : Solvers::SolverType?
          case solver
          when "z3"     then Solvers::SolverType::Z3
          when "prolog" then Solvers::SolverType::Prolog
          else               nil
          end
        end

        private def build_template(params, solver_type : Solvers::SolverType) : Skills::Template
          Skills::Template.new(
            name: params[:name].as(String),
            domain: params[:domain].as(String),
            solver: solver_type,
            signature: params[:signature].as(String),
            skeleton: params[:skeleton].as(String),
            slots: parse_slots(params[:slots].as(Hash(String, JSON::Any))),
            normalization: params[:normalization] ? parse_normalization(params[:normalization].as(Hash(String, JSON::Any))) : {} of String => String,
            uses: 0,
            successes: 0,
            created_at: Time.utc
          )
        end

        private def verify_template(template : Skills::Template, test : Bool, test_example : String?) : Hash(String, JSON::Any)?
          return unless test
          return error_response("Test example required when test=true") unless test_example

          test_result = Formalize.verify_spec(spec: test_example, solver: template.solver)
          return if test_result.success?

          {
            "status"      => JSON::Any.new("test_failed"),
            "template"    => JSON::Any.new(template.name),
            "test_result" => JSON::Any.new(test_result.to_h),
            "message"     => JSON::Any.new("Template created but test failed"),
          }
        end

        private def success_response(name : String) : Hash(String, JSON::Any)
          {
            "status"   => JSON::Any.new("success"),
            "template" => JSON::Any.new(name),
            "message"  => JSON::Any.new("Template created and added to skill library"),
          }
        end

        private def invalid_domain_response(domain : String?) : Hash(String, JSON::Any)
          error_response("Invalid domain: #{domain}. Must be one of: #{VALID_DOMAINS.join(", ")}")
        end

        private def error_response(message : String) : Hash(String, JSON::Any)
          Types::ErrorResponse.new(message).to_json.as_h
        end

        private def parse_slots(slots_hash : Hash(String, JSON::Any)) : Hash(String, String)
          result = {} of String => String
          slots_hash.each do |key, value|
            result[key] = value.as_s
          end
          result
        end

        private def parse_normalization(norm_hash : Hash(String, JSON::Any)) : Hash(String, String)
          result = {} of String => String
          norm_hash.each do |key, value|
            result[key] = value.as_s
          end
          result
        end

        def self.tool_name : String
          "chiasmus_craft"
        end

        def self.tool_description : String
          <<-DESC
          Create a new formalization template and add it to the skill library.

          The calling LLM designs the template — no API key needed. Describe your problem, then submit a template with a skeleton (formal spec with {{SLOT:name}} markers), slot definitions, and normalization recipes.

          After creation, the template appears in chiasmus_skills and chiasmus_formalize.

          Validation: checks slot/skeleton consistency, required fields, name uniqueness.
          Optional: set test=true with an example to run it through the solver.
          DESC
        end

        def self.input_schema : MCP::Protocol::Tool::Input
          ToolSchemas::ToolInputSchema.new(
            properties: {
              "name"          => ToolSchemas::Common.name_property,
              "domain"        => ToolSchemas::Common.domain_property,
              "solver"        => ToolSchemas::Common.solver_property,
              "signature"     => ToolSchemas::Common.signature_property,
              "skeleton"      => ToolSchemas::Common.skeleton_property,
              "slots"         => ToolSchemas::Common.slots_property,
              "normalization" => ToolSchemas::Common.normalization_property,
              "test"          => ToolSchemas::Common.test_property,
              "test_example"  => ToolSchemas::Common.test_example_property,
            },
            required: ["name", "domain", "solver", "signature", "skeleton", "slots"]
          ).to_mcp_input
        end
      end
    end
  end
end
