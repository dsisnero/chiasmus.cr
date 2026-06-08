# chiasmus_crig tool - Run a direct Crig prompt
require "mcp"
require "../../llm/types"

module Chiasmus
  module MCPServer
    module Tools
      class CrigTool
        def invoke(arguments : Hash(String, JSON::Any)) : Types::Response
          args = Types::CrigInput.from_json(arguments.to_json)
          prompt = args.prompt
          preamble = args.preamble || LLM::DEFAULT_PREAMBLE
          model = args.model || Crig::Providers::OpenAI::GPT_4O_MINI
          max_turns = args.max_turns

          config = LLM::SimpleConfig.new(model: model, preamble: preamble)
          return Types::ErrorResponse.new("API key not configured for selected provider") unless LLM.available?(config)

          client = LLM.client(config)
          agent = client.agent(model).preamble(preamble).build
          request = agent.prompt(prompt)
          request = request.max_turns(max_turns) if max_turns > 0
          output = request.send

          Types::CrigResponse.new(output: output, model: model)
        rescue ex
          Types::ErrorResponse.new(ex.message || ex.class.name)
        end

        def self.tool_name : String
          "chiasmus_crig"
        end

        def self.tool_description : String
          "Run a direct Crig prompt using the configured LLM provider and return the model output."
        end

        def self.input_schema : MCP::Protocol::Tool::Input
          MCP::Protocol::Tool::Input.new(
            properties: {
              "prompt" => JSON::Any.new({
                "type"        => JSON::Any.new("string"),
                "description" => JSON::Any.new("The user prompt to send through Crig"),
              }),
              "preamble" => JSON::Any.new({
                "type"        => JSON::Any.new("string"),
                "description" => JSON::Any.new("Optional agent preamble/system guidance"),
              }),
              "model" => JSON::Any.new({
                "type"        => JSON::Any.new("string"),
                "description" => JSON::Any.new("Optional Crig/OpenAI model override"),
              }),
              "max_turns" => JSON::Any.new({
                "type"        => JSON::Any.new("integer"),
                "description" => JSON::Any.new("Optional multi-turn budget for tool-enabled prompts"),
              }),
            },
            required: ["prompt"]
          )
        end
      end
    end
  end
end
