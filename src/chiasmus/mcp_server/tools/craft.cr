# chiasmus_craft tool - Create a new formalization template
require "mcp"
require "../types"
require "../tool_schemas"

module Chiasmus
  module MCPServer
    module Tools
      class CraftTool
        def invoke(arguments : Hash(String, JSON::Any)) : Types::Response
          server = MCPServer.current_server
          return Types::ErrorResponse.new("Server not available") unless server

          args = Types::CraftInput.from_json(arguments.to_json)
          result = Skills.craft_template(craft_input_to_domain(args), server.skill_library)

          Types::CraftResponse.new(
            created: result.created,
            template: result.template,
            domain: result.domain,
            solver: result.solver,
            slots: result.slots,
            tested: result.tested,
            test_result: result.test_result,
            errors: result.errors || [] of String
          )
        rescue ex
          Types::ErrorResponse.new(ex.message || ex.class.name)
        end

        private def craft_input_to_domain(args : Types::CraftInput) : Skills::CraftInput
          Skills::CraftInput.new(
            name: args.name,
            domain: args.domain,
            solver: args.solver,
            signature: args.signature,
            skeleton: args.skeleton,
            slots: args.slots.map { |s| Skills::SlotDef.new(name: s.name, description: s.description, format: s.format) },
            normalizations: args.normalizations.map { |n| Skills::Normalization.new(source: n.source, transform: n.transform) },
            tips: args.tips,
            example: args.example,
            test: args.test
          )
        end

        def self.tool_name : String
          "chiasmus_craft"
        end

        def self.tool_description : String
          <<-DESC
          Create a new formalization template and add it to the skill library.

          The calling LLM designs the template. Submit a skeleton with {{SLOT:name}} markers, slot definitions, and normalization recipes.
          Optionally set test=true with an example to run it through the solver after validation.
          DESC
        end

        def self.input_schema : MCP::Protocol::Tool::Input
          ToolSchemas::ToolInputSchema.new(
            properties: {
              "name"           => ToolSchemas::Common.name_property,
              "domain"         => ToolSchemas::Common.domain_property,
              "solver"         => ToolSchemas::Common.solver_property,
              "signature"      => ToolSchemas::Common.signature_property,
              "skeleton"       => ToolSchemas::Common.skeleton_property,
              "slots"          => ToolSchemas::Common.slots_property,
              "normalizations" => ToolSchemas::Common.normalizations_property,
              "tips"           => ToolSchemas::Common.tips_property,
              "example"        => ToolSchemas::Common.example_property,
              "test"           => ToolSchemas::Common.test_property,
            },
            required: ["name", "domain", "solver", "signature", "skeleton", "slots", "normalizations"]
          ).to_mcp_input
        end

        def self.output_schema : MCP::Protocol::Tool::Input
          MCP::Protocol::Tool::Input.new(
            properties: JSON.parse(%({"status":{"type":"string"},"created":{"type":"boolean"},"template":{"type":"string"},"domain":{"type":"string"}})).as_h
          )
        end
      end
    end
  end
end
