# chiasmus_craft tool - Create a new formalization template
require "mcp"
require "../types"
require "../tool_schemas"

module Chiasmus
  module MCPServer
    module Tools
      class CraftTool
        def invoke(arguments : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
          server = MCPServer.current_server
          return json_hash(Types::ErrorResponse.new("Server not available")) unless server

          input = parse_input(arguments)
          result = Skills.craft_template(input, server.skill_library)
          craft_hash(result)
        rescue ex
          json_hash(Types::ErrorResponse.new(ex.message || ex.class.name))
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

        private def parse_input(arguments : Hash(String, JSON::Any)) : Skills::CraftInput
          Skills::CraftInput.new(
            name: string_arg(arguments, "name"),
            domain: string_arg(arguments, "domain"),
            solver: string_arg(arguments, "solver"),
            signature: string_arg(arguments, "signature"),
            skeleton: string_arg(arguments, "skeleton"),
            slots: parse_slots(arguments["slots"]?),
            normalizations: parse_normalizations(arguments["normalizations"]?),
            tips: parse_tips(arguments["tips"]?),
            example: arguments["example"]?.try(&.as_s?),
            test: arguments["test"]?.try(&.as_bool?) || false
          )
        end

        private def string_arg(arguments : Hash(String, JSON::Any), key : String) : String
          arguments[key]?.try(&.as_s?) || ""
        end

        private def parse_slots(value : JSON::Any?) : Array(Skills::SlotDef)
          array = value.try(&.as_a?) || [] of JSON::Any
          array.map do |item|
            hash = item.as_h
            Skills::SlotDef.new(
              name: hash["name"]?.try(&.as_s?) || "",
              description: hash["description"]?.try(&.as_s?) || "",
              format: hash["format"]?.try(&.as_s?) || ""
            )
          end
        end

        private def parse_normalizations(value : JSON::Any?) : Array(Skills::Normalization)
          array = value.try(&.as_a?) || [] of JSON::Any
          array.map do |item|
            hash = item.as_h
            Skills::Normalization.new(
              source: hash["source"]?.try(&.as_s?) || "",
              transform: hash["transform"]?.try(&.as_s?) || ""
            )
          end
        end

        private def parse_tips(value : JSON::Any?) : Array(String)?
          array = value.try(&.as_a?)
          return nil unless array

          array.map(&.as_s)
        end

        private def craft_hash(result : Skills::CraftResult) : Hash(String, JSON::Any)
          {
            "created"    => JSON::Any.new(result.created),
            "template"   => json_string(result.template),
            "domain"     => json_string(result.domain),
            "solver"     => json_string(result.solver),
            "slots"      => json_int(result.slots),
            "tested"     => JSON::Any.new(result.tested),
            "testResult" => json_string(result.test_result),
            "errors"     => JSON::Any.new(string_array(result.errors || [] of String)),
          }
        end

        private def json_hash(response : Types::Response) : Hash(String, JSON::Any)
          JSON.parse(response.to_json).as_h
        end

        private def string_array(values : Array(String)) : Array(JSON::Any)
          values.map { |value| JSON::Any.new(value) }
        end

        private def json_string(value : String?) : JSON::Any
          value ? JSON::Any.new(value) : JSON::Any.new(nil)
        end

        private def json_int(value : Int32?) : JSON::Any
          if value
            JSON::Any.new(value.to_i64)
          else
            JSON::Any.new(nil)
          end
        end
      end
    end
  end
end
