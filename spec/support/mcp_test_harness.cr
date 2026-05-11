require "spec"
require "mcp"
require "json"
require "file_utils"
require "../../src/chiasmus/mcp_server/tools/verify"
require "../../src/chiasmus/mcp_server/tools/graph"

# Reusable MCP in-memory transport harness for testing chiasmus tools
# through the same boundary a real MCP client uses.
#
# Usage:
#   harness = Chiasmus::MCPTestHarness.new
#   harness.register_all_tools
#   harness.connect
#   result = harness.client.call_tool("chiasmus_verify", args)
#   harness.close
module Chiasmus
  module MCPTestHarness
    def self.new(tools : Array(String)? = nil) : Instance
      Instance.new(tools)
    end

    class Instance
      getter server : MCP::Server::Server
      @server_transport : MCP::Shared::InMemoryTransport
      @client_transport : MCP::Shared::InMemoryTransport
      @client : MCP::Client::Client?
      @tools : Array(String)?

      def initialize(@tools = nil)
        capabilities = MCP::Protocol::ServerCapabilities.new(
          tools: MCP::Protocol::ServerCapabilities::ToolsCapability.new(list_changed: true)
        )
        options = MCP::Server::ServerOptions.new(capabilities: capabilities)

        @server = MCP::Server::Server.new(
          MCP::Protocol::Implementation.new(name: "test-server", version: "1.0.0"),
          options
        )

        @server_transport = MCP::Shared::InMemoryTransport.new
        @client_transport = MCP::Shared::InMemoryTransport.new
      end

      # Access client (must call #connect first)
      def client : MCP::Client::Client
        @client || raise "MCPTestHarness not connected. Call #connect first."
      end

      # Register all 9 chiasmus tools or a specified subset
      def register_all_tools : Nil
        wanted = @tools || ALL_TOOLS
        register_tools(wanted)
      end

      private def register_tools(names : Array(String))
        names.each do |name|
          entry = TOOL_REGISTRY[name]?
          next unless entry
          tool_class, tool_name, tool_description, input_schema = entry
          tool_instance = tool_class.new
          @server.add_tool(tool_name, tool_description, input_schema) do |params|
            arguments = params.arguments || {} of String => JSON::Any
            result = tool_instance.invoke(arguments)
            content = [MCP::Protocol::TextContentBlock.new(result.to_json)] of MCP::Protocol::ContentBlock
            MCP::Protocol::CallToolResult.new(content: content)
          end
        end
      end

      # Connect transports and do handshake
      def connect : Nil
        @server_transport.other_transport = @client_transport
        @client_transport.other_transport = @server_transport

        @server.connect(@server_transport)

        client = MCP::Client::Client.new(
          MCP::Protocol::Implementation.new(name: "test-client", version: "0.0.1")
        )
        client.connect(@client_transport)
        @client = client
      end

      # Close connections
      def close : Nil
        @client.try(&.close)
        @server.close
      rescue
      end

      # List tools via transport
      def list_tools : Array(String)
        result = client.list_tools.as(MCP::Protocol::ListToolsResult)
        result.tools.map(&.name)
      end

      # Call a tool via transport and get parsed JSON result
      def call_tool(name : String, args : Hash(String, JSON::Any) = {} of String => JSON::Any) : JSON::Any
        result = client.call_tool(name, args).as(MCP::Protocol::CallToolResult)
        first_block = result.content.first.as(MCP::Protocol::TextContentBlock)
        JSON.parse(first_block.text)
      end

      # Tool registry: name → {class, tool_name, tool_description, input_schema}
      TOOL_REGISTRY = {
        "chiasmus_verify" => {MCPServer::Tools::VerifyTool, MCPServer::Tools::VerifyTool.tool_name, MCPServer::Tools::VerifyTool.tool_description, MCPServer::Tools::VerifyTool.input_schema},
        "chiasmus_graph"  => {MCPServer::Tools::GraphTool, MCPServer::Tools::GraphTool.tool_name, MCPServer::Tools::GraphTool.tool_description, MCPServer::Tools::GraphTool.input_schema},
      }

      ALL_TOOLS = TOOL_REGISTRY.keys
    end
  end
end
