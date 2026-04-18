# chiasmus_craft tool - Create a new formalization template
require "mcp"
require "../types"
require "../tool_schemas"

module Chiasmus
  module MCPServer
    module Tools
      class CraftTool
        def invoke(arguments : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
          name = arguments["name"]?.try(&.as_s?)
          domain = arguments["domain"]?.try(&.as_s?)
          solver = arguments["solver"]?.try(&.as_s?)
          signature = arguments["signature"]?.try(&.as_s?)
          skeleton = arguments["skeleton"]?.try(&.as_s?)
          slots = arguments["slots"]?.try(&.as_h?)
          normalization = arguments["normalization"]?.try(&.as_h?)
          test = arguments["test"]?.try(&.as_bool?) || false
          test_example = arguments["test_example"]?.try(&.as_s?)

          return Types::ErrorResponse.new("Missing required parameters: name, domain, solver, signature, skeleton, slots").to_json.as_h unless name && domain && solver && signature && skeleton && slots

          solver_type = case solver
                        when "z3"     then Solvers::SolverType::Z3
                        when "prolog" then Solvers::SolverType::Prolog
                        else
                          return Types::ErrorResponse.new("Unknown solver: #{solver}").to_json.as_h
                        end

          # Validate domain
          valid_domains = ["authorization", "configuration", "dependency", "validation", "rules", "analysis", "custom"]
          unless valid_domains.includes?(domain)
            return Types::ErrorResponse.new("Invalid domain: #{domain}. Must be one of: #{valid_domains.join(", ")}").to_json.as_h
          end

          # Parse slots
          slot_defs = parse_slots(slots)

          # Parse normalization recipes
          norm_recipes = parse_normalization(normalization) if normalization

          # Create template
          template = Skills::Template.new(
            name: name,
            domain: domain,
            solver: solver_type,
            signature: signature,
            skeleton: skeleton,
            slots: slot_defs,
            normalization: norm_recipes || {} of String => String,
            uses: 0,
            successes: 0,
            created_at: Time.utc
          )

          # Test if requested
          if test
            return Types::ErrorResponse.new("Test example required when test=true").to_json.as_h unless test_example

            # Run verification test
            test_result = Formalize.verify_spec(
              spec: test_example,
              solver: solver_type
            )

            unless test_result.success?
              return {
                "status"      => JSON::Any.new("test_failed"),
                "template"    => JSON::Any.new(name),
                "test_result" => JSON::Any.new(test_result.to_h),
                "message"     => JSON::Any.new("Template created but test failed"),
              }
            end
          end

          # Add to skill library
          Skills::Library.instance.add_template(template)

          {
            "status"   => JSON::Any.new("success"),
            "template" => JSON::Any.new(name),
            "message"  => JSON::Any.new("Template created and added to skill library"),
          }
        rescue ex
          Types::ErrorResponse.new(ex.message || ex.class.name).to_json.as_h
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
