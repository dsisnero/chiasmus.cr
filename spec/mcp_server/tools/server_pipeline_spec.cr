require "../../spec_helper"
require "mcp"

describe "server.cr tool pipeline integration" do
  describe "chiasmus_verify through full MCP stack" do
    it "register_tools wires invoke → to_json → CallToolResult correctly" do
      capabilities = MCP::Protocol::ServerCapabilities.new(
        tools: MCP::Protocol::ServerCapabilities::ToolsCapability.new(list_changed: true)
      )
      mcp = MCP::Server::Server.new(
        MCP::Protocol::Implementation.new(name: "test", version: "1.0"),
        MCP::Server::ServerOptions.new(capabilities: capabilities)
      )

      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      mcp.add_tool(
        Chiasmus::MCPServer::Tools::VerifyTool.tool_name,
        Chiasmus::MCPServer::Tools::VerifyTool.tool_description,
        Chiasmus::MCPServer::Tools::VerifyTool.input_schema
      ) do |params|
        args = params.arguments || {} of String => JSON::Any
        result = tool.invoke(args)
        json = result.to_json
        structured = JSON.parse(json).as_h
        MCP::Protocol::CallToolResult.new(
          content: [MCP::Protocol::TextContentBlock.new(json)] of MCP::Protocol::ContentBlock,
          structured_content: structured
        )
      end

      st = MCP::Shared::InMemoryTransport.new
      ct = MCP::Shared::InMemoryTransport.new
      st.other_transport = ct
      ct.other_transport = st
      mcp.connect(st)

      client = MCP::Client::Client.new(
        MCP::Protocol::Implementation.new(name: "test", version: "1.0")
      )
      client.connect(ct)

      result = client.call_tool("chiasmus_verify", {
        "solver" => JSON::Any.new("z3"),
        "input"  => JSON::Any.new("(declare-const x Int) (assert (> x 3))"),
      }).as(MCP::Protocol::CallToolResult)

      result.is_error.should be_falsey
      structured = result.structured_content.not_nil!
      structured["status"].as_s.should eq("success")
      structured.has_key?("result").should be_true

      text = result.content.first.as(MCP::Protocol::TextContentBlock).text
      text.should contain("sat")

      client.close rescue nil
      mcp.close rescue nil
    end

    it "returns structured error through MCP pipeline" do
      capabilities = MCP::Protocol::ServerCapabilities.new(
        tools: MCP::Protocol::ServerCapabilities::ToolsCapability.new(list_changed: true)
      )
      mcp = MCP::Server::Server.new(
        MCP::Protocol::Implementation.new(name: "test", version: "1.0"),
        MCP::Server::ServerOptions.new(capabilities: capabilities)
      )

      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      mcp.add_tool(
        Chiasmus::MCPServer::Tools::VerifyTool.tool_name,
        Chiasmus::MCPServer::Tools::VerifyTool.tool_description,
        Chiasmus::MCPServer::Tools::VerifyTool.input_schema
      ) do |params|
        args = params.arguments || {} of String => JSON::Any
        result = tool.invoke(args)
        json = result.to_json
        structured = JSON.parse(json).as_h
        MCP::Protocol::CallToolResult.new(
          content: [MCP::Protocol::TextContentBlock.new(json)] of MCP::Protocol::ContentBlock,
          structured_content: structured
        )
      end

      st = MCP::Shared::InMemoryTransport.new
      ct = MCP::Shared::InMemoryTransport.new
      st.other_transport = ct
      ct.other_transport = st
      mcp.connect(st)

      client = MCP::Client::Client.new(
        MCP::Protocol::Implementation.new(name: "test", version: "1.0")
      )
      client.connect(ct)

      result = client.call_tool("chiasmus_verify", {
        "solver" => JSON::Any.new("prolog"),
        "input"  => JSON::Any.new("parent(tom, bob)."),
      }).as(MCP::Protocol::CallToolResult)

      structured = result.structured_content.not_nil!
      structured["status"].as_s.should eq("error")
      structured["error"].as_s.should match(/query/i)

      client.close rescue nil
      mcp.close rescue nil
    end
  end

  describe "chiasmus_crig through full MCP stack" do
    it "returns structured content including status and error fields" do
      capabilities = MCP::Protocol::ServerCapabilities.new(
        tools: MCP::Protocol::ServerCapabilities::ToolsCapability.new(list_changed: true)
      )
      mcp = MCP::Server::Server.new(
        MCP::Protocol::Implementation.new(name: "test", version: "1.0"),
        MCP::Server::ServerOptions.new(capabilities: capabilities)
      )

      tool = Chiasmus::MCPServer::Tools::CrigTool.new
      mcp.add_tool(
        Chiasmus::MCPServer::Tools::CrigTool.tool_name,
        Chiasmus::MCPServer::Tools::CrigTool.tool_description,
        Chiasmus::MCPServer::Tools::CrigTool.input_schema
      ) do |params|
        args = params.arguments || {} of String => JSON::Any
        result = tool.invoke(args)
        json = result.to_json
        structured = JSON.parse(json).as_h
        MCP::Protocol::CallToolResult.new(
          content: [MCP::Protocol::TextContentBlock.new(json)] of MCP::Protocol::ContentBlock,
          structured_content: structured
        )
      end

      st = MCP::Shared::InMemoryTransport.new
      ct = MCP::Shared::InMemoryTransport.new
      st.other_transport = ct
      ct.other_transport = st
      mcp.connect(st)

      client = MCP::Client::Client.new(
        MCP::Protocol::Implementation.new(name: "test", version: "1.0")
      )
      client.connect(ct)

      result = client.call_tool("chiasmus_crig", {} of String => JSON::Any).as(MCP::Protocol::CallToolResult)

      structured = result.structured_content.not_nil!
      structured["status"].as_s.should eq("error")
      structured["error"].as_s.should contain("prompt")

      client.close rescue nil
      mcp.close rescue nil
    end
  end
end
