# chiasmus_crig tool - Run a direct Crig prompt
require "mcp"
require "../../llm/types"

module Chiasmus
  module MCPServer
    module Tools
      class CrigTool
        def invoke(arguments : Hash(String, JSON::Any)) : Hash(String, JSON::Any)
          prompt = arguments["prompt"]?.try(&.as_s?)
          preamble = arguments["preamble"]?.try(&.as_s?) || LLM::DEFAULT_PREAMBLE
          model = arguments["model"]?.try(&.as_s?) || Crig::Providers::OpenAI::GPT_4O_MINI
          max_turns = arguments["max_turns"]?.try(&.as_i?) || 0

          return error_hash("Missing required parameter: prompt") unless prompt

          # Create config for the requested model
          config = LLM::SimpleConfig.new(model: model, preamble: preamble)
          return error_hash("API key not configured for selected provider") unless LLM.available?(config)

          # Use the client method to create agent with specific config
          client = LLM.client(config)
          agent = client.agent(model).preamble(preamble).build
          request = agent.prompt(prompt)
          request = request.max_turns(max_turns) if max_turns > 0
          output = request.send

          {
            "status" => JSON::Any.new("success"),
            "output" => JSON::Any.new(output),
            "model"  => JSON::Any.new(model),
          }
        rescue ex
          error_hash(ex.message || ex.class.name)
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

        def self.call(request : MCP::Protocol::CallToolRequestParams) : MCP::Protocol::CallToolResult
          result = new.invoke(request.arguments)
          if result["status"].as_s == "success"
            content = [MCP::Protocol::TextContentBlock.new(result["output"].as_s)] of MCP::Protocol::ContentBlock
            MCP::Protocol::CallToolResult.new(content: content)
          else
            content = [MCP::Protocol::TextContentBlock.new(result["error"].as_s)] of MCP::Protocol::ContentBlock
            MCP::Protocol::CallToolResult.new(content: content, is_error: true)
          end
        end

        private def error_hash(message : String) : Hash(String, JSON::Any)
          {
            "status" => JSON::Any.new("error"),
            "error"  => JSON::Any.new(message),
          }
        end
      end
    end
  end
end
