# chiasmus_crig tool - Run a direct Crig prompt via rig_tool macro
require "mcp"
require "crig"
require "../types"
require "../../llm/types"

module Chiasmus
  module MCPServer
    module Tools
      class CrigTool
        def self.default_model_name : String
          provider = ENV["CHIASMUS_LLM_PROVIDER"]? || Chiasmus::LLM::DEFAULT_PROVIDER
          ENV["CHIASMUS_LLM_MODEL"]? || Chiasmus::LLM::SimpleConfig.default_model_for(provider)
        end

        def self.resolve_config(
          model : String,
          preamble : String = Chiasmus::LLM::DEFAULT_PREAMBLE,
        ) : Chiasmus::LLM::SimpleConfig
          # Respect an explicit model choice over a stale provider env so the
          # matching provider key is selected for the request.
          Chiasmus::LLM::SimpleConfig.new(provider: "", model: model, preamble: preamble)
        end
      end
    end
  end
end

# Crig-native tool definition using rig_tool macro
Crig.rig_tool("Run a direct Crig prompt using the configured LLM provider and return the model output.",
  {
    prompt:    "The user prompt to send through Crig",
    preamble:  "Optional agent preamble/system guidance",
    model:     "Optional Crig/OpenAI model override",
    max_turns: "Optional multi-turn budget for tool-enabled prompts",
  },
  [:prompt]
) do
  def crig_prompt(
    prompt : String,
    preamble : String = Chiasmus::LLM::DEFAULT_PREAMBLE,
    model : String = Chiasmus::MCPServer::Tools::CrigTool.default_model_name,
    max_turns : Int32 = 0,
  ) : Chiasmus::MCPServer::Types::CrigResponse
    config = Chiasmus::MCPServer::Tools::CrigTool.resolve_config(model, preamble)
    raise "API key not configured for selected provider" unless Chiasmus::LLM.available?(config)

    client = Chiasmus::LLM.client(config)
    agent = client.agent(model).preamble(preamble).build
    request = agent.prompt(prompt)
    request = request.max_turns(max_turns) if max_turns > 0
    output = request.send_async.receive.unwrap

    Chiasmus::MCPServer::Types::CrigResponse.new(output: output, model: model)
  end
end

module Chiasmus
  module MCPServer
    module Tools
      # MCP wrapper around the Crig-native rig_tool
      class CrigTool
        @@before_async_result_send_hook : Proc(Nil)? = nil

        def invoke(arguments : Hash(String, JSON::Any)) : Types::Response
          invoke_async(arguments).receive || Types::ErrorResponse.new("Crig request did not produce a response")
        end

        def self.tool_name : String
          "chiasmus_crig"
        end

        def self.tool_description : String
          CRIG_PROMPT.description
        end

        def self.input_schema : MCP::Protocol::Tool::Input
          props = Hash(String, JSON::Any).new
          required = [] of String
          params = CRIG_PROMPT.parameters
          if params_props = params["properties"]?
            params_props.as_h.each { |k, v| props[k] = v }
          end
          params["required"]?.try(&.as_a).try(&.each { |req| required << req.as_s })
          MCP::Protocol::Tool::Input.new(properties: props, required: required)
        end

        def self.output_schema : MCP::Protocol::Tool::Input
          MCP::Protocol::Tool::Input.new(
            properties: JSON.parse(%({"status":{"type":"string"},"output":{"type":"string"},"model":{"type":"string"}})).as_h
          )
        end

        def self.set_before_async_result_send_hook_for_test(&block : ->) : Nil
          @@before_async_result_send_hook = block
        end

        def self.clear_before_async_result_send_hook_for_test : Nil
          @@before_async_result_send_hook = nil
        end

        private def invoke_async(arguments : Hash(String, JSON::Any)) : Channel(Types::Response)
          channel = Channel(Types::Response).new(1)

          spawn do
            result = begin
              args_json = normalized_arguments(arguments).to_json
              output = CRIG_PROMPT.call(args_json)
              Types::CrigResponse.from_json(output).as(Types::Response)
            rescue ex
              Types::ErrorResponse.new(ex.message || ex.class.name).as(Types::Response)
            end

            @@before_async_result_send_hook.try(&.call)
            channel.send(result)
          ensure
            channel.close
          end

          channel
        end

        private def normalized_arguments(arguments : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
          normalized = arguments.dup
          normalized["preamble"] ||= JSON::Any.new(Chiasmus::LLM::DEFAULT_PREAMBLE)
          normalized["model"] ||= JSON::Any.new(self.class.default_model_name)
          normalized["max_turns"] ||= JSON::Any.new(0_i64)
          normalized
        end
      end
    end
  end
end
