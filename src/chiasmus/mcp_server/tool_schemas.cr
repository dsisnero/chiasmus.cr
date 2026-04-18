# MCP tool input schemas using JSON::Serializable and json-schema
require "json"
require "json-schema"

module Chiasmus
  module MCPServer
    module ToolSchemas
      # Base schema properties
      alias Property = SchemaProperty | ArraySchemaProperty | ObjectSchemaProperty | BooleanSchemaProperty

      struct SchemaProperty
        include JSON::Serializable

        getter type : String
        getter description : String
        getter enum : Array(String)?

        def initialize(@type : String, @description : String, @enum : Array(String)? = nil)
        end

        def to_json_schema : Hash(String, JSON::Any)
          schema = {
            "type"        => @type,
            "description" => @description,
          }
          schema["enum"] = @enum if @enum
          schema.transform_values { |v| JSON::Any.new(v) }
        end
      end

      struct ArraySchemaProperty
        include JSON::Serializable

        getter type : String = "array"
        getter description : String
        getter items : Hash(String, String)

        def initialize(@description : String, items_type : String = "string")
          @items = {"type" => items_type}
        end

        def to_json_schema : Hash(String, JSON::Any)
          {
            "type"        => @type,
            "items"       => JSON::Any.new(@items.transform_values { |v| JSON::Any.new(v) }),
            "description" => @description,
          }.transform_values { |v| JSON::Any.new(v) }
        end
      end

      struct ObjectSchemaProperty
        include JSON::Serializable

        getter type : String = "object"
        getter description : String

        def initialize(@description : String)
        end

        def to_json_schema : Hash(String, JSON::Any)
          {
            "type"        => @type,
            "description" => @description,
          }.transform_values { |v| JSON::Any.new(v) }
        end
      end

      struct BooleanSchemaProperty
        include JSON::Serializable

        getter type : String = "boolean"
        getter description : String

        def initialize(@description : String)
        end

        def to_json_schema : Hash(String, JSON::Any)
          {
            "type"        => @type,
            "description" => @description,
          }.transform_values { |v| JSON::Any.new(v) }
        end
      end

      # Tool input schema
      struct ToolInputSchema
        include JSON::Serializable

        getter type : String = "object"
        getter properties : Hash(String, Property)
        getter required : Array(String)

        def initialize(@properties : Hash(String, Property), @required : Array(String))
        end

        def to_mcp_input : MCP::Protocol::Tool::Input
          properties_json = {} of String => JSON::Any

          @properties.each do |key, prop|
            properties_json[key] = JSON::Any.new(prop.to_json_schema)
          end

          MCP::Protocol::Tool::Input.new(
            properties: properties_json,
            required: @required
          )
        end

        # Generate JSON Schema for this tool input
        def to_json_schema : Hash(String, JSON::Any)
          properties = {} of String => JSON::Any
          @properties.each do |key, prop|
            properties[key] = JSON::Any.new(prop.to_json_schema)
          end

          {
            "type"       => @type,
            "properties" => JSON::Any.new(properties),
            "required"   => JSON::Any.new(@required),
          }.transform_values { |v| JSON::Any.new(v) }
        end
      end

      # Common schemas
      module Common
        def self.solver_property : SchemaProperty
          SchemaProperty.new(
            type: "string",
            description: "Solver type",
            enum: ["z3", "prolog"]
          )
        end

        def self.input_property : SchemaProperty
          SchemaProperty.new(
            type: "string",
            description: "Input specification or code"
          )
        end

        def self.files_property : ArraySchemaProperty
          ArraySchemaProperty.new("Absolute file paths to analyze")
        end

        def self.analysis_property : SchemaProperty
          SchemaProperty.new(
            type: "string",
            description: "Which analysis to run",
            enum: ["summary", "callers", "callees", "reachability", "dead-code", "cycles", "path", "impact", "facts"]
          )
        end

        def self.target_property : SchemaProperty
          SchemaProperty.new(
            type: "string",
            description: "Target function/identifier"
          )
        end

        def self.from_property : SchemaProperty
          SchemaProperty.new(
            type: "string",
            description: "Source function/identifier"
          )
        end

        def self.to_property : SchemaProperty
          SchemaProperty.new(
            type: "string",
            description: "Destination function/identifier"
          )
        end

        def self.entry_points_property : ArraySchemaProperty
          ArraySchemaProperty.new("Entry point functions for analysis")
        end

        def self.problem_property : SchemaProperty
          SchemaProperty.new(
            type: "string",
            description: "Natural language description of the problem"
          )
        end

        def self.spec_property : SchemaProperty
          SchemaProperty.new(
            type: "string",
            description: "Formal specification"
          )
        end

        def self.name_property : SchemaProperty
          SchemaProperty.new(
            type: "string",
            description: "Kebab-case unique identifier (e.g. 'api-rate-limit-check')"
          )
        end

        def self.domain_property : SchemaProperty
          SchemaProperty.new(
            type: "string",
            description: "Problem domain",
            enum: ["authorization", "configuration", "dependency", "validation", "rules", "analysis", "custom"]
          )
        end

        def self.signature_property : SchemaProperty
          SchemaProperty.new(
            type: "string",
            description: "Natural language description for search/matching"
          )
        end

        def self.skeleton_property : SchemaProperty
          SchemaProperty.new(
            type: "string",
            description: "Template skeleton with {{SLOT:name}} markers"
          )
        end

        def self.slots_property : ObjectSchemaProperty
          ObjectSchemaProperty.new("Slot definitions: {slot_name: description}")
        end

        def self.normalization_property : ObjectSchemaProperty
          ObjectSchemaProperty.new("Optional normalization recipes: {slot_name: recipe}")
        end

        def self.test_property : BooleanSchemaProperty
          BooleanSchemaProperty.new("Test the template with an example (requires test_example)")
        end

        def self.test_example_property : SchemaProperty
          SchemaProperty.new(
            type: "string",
            description: "Example spec to test the template"
          )
        end

        def self.prompt_property : SchemaProperty
          SchemaProperty.new(
            type: "string",
            description: "Prompt for LLM"
          )
        end

        def self.preamble_property : SchemaProperty
          SchemaProperty.new(
            type: "string",
            description: "Optional preamble for LLM"
          )
        end

        def self.model_property : SchemaProperty
          SchemaProperty.new(
            type: "string",
            description: "LLM model to use"
          )
        end

        def self.max_turns_property : SchemaProperty
          SchemaProperty.new(
            type: "integer",
            description: "Maximum number of turns for conversation"
          )
        end
      end
    end
  end
end
