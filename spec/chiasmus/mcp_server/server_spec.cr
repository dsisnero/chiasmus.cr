require "../../spec_helper"
require "mcp"

describe "Chiasmus MCP Server Transport" do
  mcp_server = uninitialized MCP::Server::Server
  client = uninitialized MCP::Client::Client
  library = uninitialized Chiasmus::Skills::Library

  before_all do
    agent = Chiasmus::LLM::MockAdapter.create_agent
    chiasmus = Chiasmus::MCPServer::Server.with_agent(agent)
    library = chiasmus.skill_library

    mcp_server = build_mcp_server
    register_tools_on(mcp_server)

    server_t, client_t = linked_transports
    mcp_server.connect(server_t)

    client_t_instance = MCP::Client::Client.new(
      MCP::Protocol::Implementation.new(name: "test-client", version: "1.0.0")
    )
    client_t_instance.connect(client_t)
    client = client_t_instance
  end

  after_all do
    library.close rescue nil
  end

  describe "initialize and tools/list" do
    it "accepts MCP initialize and returns server info" do
      result = client.list_tools
      result.should_not be_nil
      names = result.not_nil!.tools.map(&.name)
      names.should contain("chiasmus_verify")
    end

    it "lists all 11 expected tools" do
      result = client.list_tools.not_nil!
      names = result.tools.map(&.name)

      expected = [
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
      expected.each { |tool| names.should contain(tool) }
    end

    it "tools have descriptions and input schemas" do
      result = client.list_tools.not_nil!

      verify_tool = result.tools.find { |t| t.name == "chiasmus_verify" }
      verify_tool.should_not be_nil
      verify_tool.not_nil!.description.should_not be_nil
      verify_tool.not_nil!.description.not_nil!.should contain("z3")
      verify_tool.not_nil!.input_schema.properties.has_key?("solver").should be_true
      verify_tool.not_nil!.input_schema.properties.has_key?("spec").should be_true
    end
  end

  describe "tools/call via transport" do
    it "chiasmus_verify returns sat for Z3 tautology" do
      result = client.call_tool("chiasmus_verify", {
        "solver" => JSON::Any.new("z3"),
        "spec"   => JSON::Any.new("(declare-const x Int)\n(assert (= x x))"),
      }).as(MCP::Protocol::CallToolResult)
      result.content.size.should eq(1)

      content_block = result.content.first.as(MCP::Protocol::TextContentBlock)
      parsed = JSON.parse(content_block.text)
      parsed["status"].as_s.should eq("success")
      parsed["result"]["status"].as_s.should eq("sat")
    end

    it "chiasmus_verify returns error for missing parameters" do
      result = client.call_tool("chiasmus_verify", {} of String => JSON::Any).as(MCP::Protocol::CallToolResult)
      content_block = result.content.first.as(MCP::Protocol::TextContentBlock)
      parsed = JSON.parse(content_block.text)
      parsed["status"].as_s.should eq("error")
    end
  end
end

private def linked_transports
  server_t = MCP::Shared::InMemoryTransport.new
  client_t = MCP::Shared::InMemoryTransport.new
  server_t.other_transport = client_t
  client_t.other_transport = server_t
  {server_t, client_t}
end

private def build_mcp_server
  capabilities = MCP::Protocol::ServerCapabilities.new(
    tools: MCP::Protocol::ServerCapabilities::ToolsCapability.new(list_changed: true)
  )
  options = MCP::Server::ServerOptions.new(capabilities: capabilities)

  MCP::Server::Server.new(
    MCP::Protocol::Implementation.new(name: "chiasmus", version: Chiasmus::VERSION),
    options
  )
end

private def register_tools_on(mcp_server : MCP::Server::Server)
  tools = [
    {Chiasmus::MCPServer::Tools::VerifyTool, Chiasmus::MCPServer::Tools::VerifyTool.tool_name, Chiasmus::MCPServer::Tools::VerifyTool.tool_description, Chiasmus::MCPServer::Tools::VerifyTool.input_schema},
    {Chiasmus::MCPServer::Tools::SkillsTool, Chiasmus::MCPServer::Tools::SkillsTool.tool_name, Chiasmus::MCPServer::Tools::SkillsTool.tool_description, Chiasmus::MCPServer::Tools::SkillsTool.input_schema},
    {Chiasmus::MCPServer::Tools::FormalizeTool, Chiasmus::MCPServer::Tools::FormalizeTool.tool_name, Chiasmus::MCPServer::Tools::FormalizeTool.tool_description, Chiasmus::MCPServer::Tools::FormalizeTool.input_schema},
    {Chiasmus::MCPServer::Tools::SolveTool, Chiasmus::MCPServer::Tools::SolveTool.tool_name, Chiasmus::MCPServer::Tools::SolveTool.tool_description, Chiasmus::MCPServer::Tools::SolveTool.input_schema},
    {Chiasmus::MCPServer::Tools::LearnTool, Chiasmus::MCPServer::Tools::LearnTool.tool_name, Chiasmus::MCPServer::Tools::LearnTool.tool_description, Chiasmus::MCPServer::Tools::LearnTool.input_schema},
    {Chiasmus::MCPServer::Tools::LintTool, Chiasmus::MCPServer::Tools::LintTool.tool_name, Chiasmus::MCPServer::Tools::LintTool.tool_description, Chiasmus::MCPServer::Tools::LintTool.input_schema},
    {Chiasmus::MCPServer::Tools::GraphTool, Chiasmus::MCPServer::Tools::GraphTool.tool_name, Chiasmus::MCPServer::Tools::GraphTool.tool_description, Chiasmus::MCPServer::Tools::GraphTool.input_schema},
    {Chiasmus::MCPServer::Tools::MapTool, Chiasmus::MCPServer::Tools::MapTool.tool_name, Chiasmus::MCPServer::Tools::MapTool.tool_description, Chiasmus::MCPServer::Tools::MapTool.input_schema},
    {Chiasmus::MCPServer::Tools::SearchTool, Chiasmus::MCPServer::Tools::SearchTool.tool_name, Chiasmus::MCPServer::Tools::SearchTool.tool_description, Chiasmus::MCPServer::Tools::SearchTool.input_schema},
    {Chiasmus::MCPServer::Tools::CraftTool, Chiasmus::MCPServer::Tools::CraftTool.tool_name, Chiasmus::MCPServer::Tools::CraftTool.tool_description, Chiasmus::MCPServer::Tools::CraftTool.input_schema},
    {Chiasmus::MCPServer::Tools::ReviewTool, Chiasmus::MCPServer::Tools::ReviewTool.tool_name, Chiasmus::MCPServer::Tools::ReviewTool.tool_description, Chiasmus::MCPServer::Tools::ReviewTool.input_schema},
  ]

  tools.each do |(tool_class, name, description, input_schema)|
    tool_instance = tool_class.new
    mcp_server.add_tool(name, description, input_schema) do |params|
      arguments = params.arguments || {} of String => JSON::Any
      result = tool_instance.invoke(arguments)
      content = [MCP::Protocol::TextContentBlock.new(result.to_json)] of MCP::Protocol::ContentBlock
      MCP::Protocol::CallToolResult.new(content: content)
    end
  end
end
