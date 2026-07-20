require "../../spec_helper"
require "mcp"
require "crig"

private def build_rmcp_test_client_and_server : {MCP::Client::Client, MCP::Server::Server}
  client_transport, server_transport = MCP::Shared::InMemoryTransport.create_linked_pair

  server = MCP::Server::Server.new(
    MCP::Protocol::Implementation.new(name: "rmcp-test-server", version: "1.0.0"),
    MCP::Server::ServerOptions.new(
      capabilities: MCP::Protocol::ServerCapabilities.new(
        tools: MCP::Protocol::ServerCapabilities::ToolsCapability.new(list_changed: true)
      )
    )
  )
  server.connect(server_transport)

  client = MCP::Client::Client.new(
    MCP::Protocol::Implementation.new(name: "rmcp-test-client", version: "1.0.0")
  )
  client.connect(client_transport)

  {client, server}
end

describe Crig::McpTool do
  it "renders async call_tool results from MCP clients" do
    client, server = build_rmcp_test_client_and_server
    definition = MCP::Protocol::Tool.new(
      name: "sum",
      description: "Add numbers",
      input_schema: MCP::Protocol::Tool::Input.new(
        properties: {
          "x" => JSON::Any.new({"type" => JSON::Any.new("number")}),
          "y" => JSON::Any.new({"type" => JSON::Any.new("number")}),
        },
        required: ["x", "y"]
      )
    )

    server.add_tool("sum", "Add numbers", definition.input_schema) do |request|
      x = request.arguments.not_nil!["x"].as_i
      y = request.arguments.not_nil!["y"].as_i
      MCP::Protocol::CallToolResult.new([MCP::Protocol::TextContentBlock.new((x + y).to_s)] of MCP::Protocol::ContentBlock)
    end

    tool = Crig::McpTool.from_mcp_server(definition, client)
    result = tool.call_async(%({"x":2,"y":5})).receive

    result.success?.should be_true
    result.unwrap.should eq("7")

    client.close rescue nil
    server.close rescue nil
  end
end
