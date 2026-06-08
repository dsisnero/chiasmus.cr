# chiasmus_crig tool - Run a direct Crig prompt via rig_tool macro
require "mcp"
require "crig"
require "../../llm/types"

# Crig-native tool definition using rig_tool macro
Crig.rig_tool("Run a direct Crig prompt using the configured LLM provider and return the model output.",
  {
    "prompt"    => "The user prompt to send through Crig",
    "preamble"  => "Optional agent preamble/system guidance",
    "model"     => "Optional Crig/OpenAI model override",
    "max_turns" => "Optional multi-turn budget for tool-enabled prompts",
  },
  ["prompt"]
) do
  def crig_prompt(
    prompt : String,
    preamble : String = Chiasmus::LLM::DEFAULT_PREAMBLE,
    model : String = Crig::Providers::OpenAI::GPT_4O_MINI,
    max_turns : Int32 = 0,
  ) : Chiasmus::MCPServer::Types::CrigResponse
    config = Chiasmus::LLM::SimpleConfig.new(model: model, preamble: preamble)
    raise "API key not configured for selected provider" unless Chiasmus::LLM.available?(config)

    client = Chiasmus::LLM.client(config)
    agent = client.agent(model).preamble(preamble).build
    request = agent.prompt(prompt)
    request = request.max_turns(max_turns) if max_turns > 0
    output = request.send

    Chiasmus::MCPServer::Types::CrigResponse.new(output: output, model: model)
  end
end

module Chiasmus
  module MCPServer
    module Tools
      # MCP wrapper around the Crig-native rig_tool
      class CrigTool
        def invoke(arguments : Hash(String, JSON::Any)) : Types::Response
          args_json = arguments.to_json
          output = CRIG_PROMPT.call(args_json)
          Types::CrigResponse.from_json(output)
        rescue ex
          Types::ErrorResponse.new(ex.message || ex.class.name)
        end

        def self.tool_name : String
          "chiasmus_crig"
        end

        def self.tool_description : String
          CRIG_PROMPT.definition("").description
        end

        def self.input_schema : MCP::Protocol::Tool::Input
          defn = CRIG_PROMPT.definition("")
          props = Hash(String, JSON::Any).new
          required = [] of String
          if params = defn.parameters
            if params_props = params["properties"]?
              params_props.as_h.each { |k, v| props[k] = v }
            end
            params["required"]?.try(&.as_a).try(&.each { |req| required << req.as_s })
          end
          MCP::Protocol::Tool::Input.new(properties: props, required: required)
        end
      end
    end
  end
end
