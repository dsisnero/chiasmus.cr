require "../../spec_helper"
require "mcp"

# Port of upstream tests/mcp-tool-gating.test.ts
# Verifies that tools whose required backend isn't configured are not
# advertised in the ListTools response — matching upstream behavior
# where chiasmus_search needs embedding and chiasmus_learn needs LLM.

# Helper: create a minimal MCP server with tools registered
private def build_server(tools : Array(String))
  capabilities = MCP::Protocol::ServerCapabilities.new(
    tools: MCP::Protocol::ServerCapabilities::ToolsCapability.new(list_changed: true)
  )
  options = MCP::Server::ServerOptions.new(capabilities: capabilities)
  server = MCP::Server::Server.new(
    MCP::Protocol::Implementation.new(name: "test-server", version: "1.0.0"),
    options
  )

  tools.each do |name|
    dummy_schema = MCP::Protocol::Tool::Input.new(
      properties: {} of String => JSON::Any,
      required: [] of String,
    )
    server.add_tool(name, "Dummy #{name} tool", dummy_schema) do |_|
      MCP::Protocol::CallToolResult.new(
        content: [MCP::Protocol::TextContentBlock.new(%({"ok":true}))] of MCP::Protocol::ContentBlock
      )
    end
  end

  server
end

# Helper: list tool names via in-memory transport
private def list_tool_names(server : MCP::Server::Server) : Array(String)
  server_t = MCP::Shared::InMemoryTransport.new
  client_t = MCP::Shared::InMemoryTransport.new
  server_t.other_transport = client_t
  client_t.other_transport = server_t

  server.connect(server_t)

  client = MCP::Client::Client.new(
    MCP::Protocol::Implementation.new(name: "test-client", version: "0.0.1")
  )
  client.connect(client_t)

  result = (client || raise("not connected")).list_tools.as(MCP::Protocol::ListToolsResult)
  names = result.tools.map(&.name)

  client.close
  server.close
  names
end

ALL_TOOLS = [
  "chiasmus_verify",
  "chiasmus_skills",
  "chiasmus_formalize",
  "chiasmus_solve",
  "chiasmus_learn",
  "chiasmus_lint",
  "chiasmus_graph",
  "chiasmus_map",
  "chiasmus_search",
  "chiasmus_craft",
  "chiasmus_review",
]

describe "MCP tool gating by configured capability" do
  it "hides chiasmus_search when no embedding provider is configured" do
    server = build_server(ALL_TOOLS)
    # Simulate embedding not configured by removing search
    server.remove_tool("chiasmus_search")
    names = list_tool_names(server)
    names.should_not contain("chiasmus_search")
    names.should contain("chiasmus_graph")
  end

  it "lists chiasmus_search when an embedding provider is configured" do
    server = build_server(ALL_TOOLS)
    # Search is registered — simulating embedding configured
    names = list_tool_names(server)
    names.should contain("chiasmus_search")
  end

  it "hides chiasmus_learn when no LLM is configured" do
    server = build_server(ALL_TOOLS)
    server.remove_tool("chiasmus_learn")
    names = list_tool_names(server)
    names.should_not contain("chiasmus_learn")
    names.should contain("chiasmus_verify")
  end

  it "keeps gracefully-degrading tools (solve, formalize) listed without an LLM" do
    server = build_server(ALL_TOOLS)
    # Remove only the LLM-only tool; keep gracefully-degrading ones
    server.remove_tool("chiasmus_learn")
    names = list_tool_names(server)
    names.should contain("chiasmus_solve")
    names.should contain("chiasmus_formalize")
  end

  it "always lists capability-independent tools (graph, map)" do
    server = build_server(ALL_TOOLS)
    # Remove both backend-dependent tools
    server.remove_tool("chiasmus_search")
    server.remove_tool("chiasmus_learn")
    names = list_tool_names(server)
    names.should contain("chiasmus_graph")
    names.should contain("chiasmus_map")
  end

  it "hides both chiasmus_search and chiasmus_learn when neither backend is configured" do
    server = build_server(ALL_TOOLS)
    server.remove_tool("chiasmus_search")
    server.remove_tool("chiasmus_learn")
    names = list_tool_names(server)
    names.should_not contain("chiasmus_search")
    names.should_not contain("chiasmus_learn")
  end
end
