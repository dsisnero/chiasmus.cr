require "../../spec_helper"
require "mcp"

# Helper: create server with MockCompletionModel (no real LLM, no embedding),
# connect via in-memory transport, and return list of tool names.
private def build_and_list_tools : Array(String)
  server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
  transport = server.build_mcp_transport

  st = MCP::Shared::InMemoryTransport.new
  ct = MCP::Shared::InMemoryTransport.new
  st.other_transport = ct
  ct.other_transport = st
  transport.connect(st)

  client = MCP::Client::Client.new(
    MCP::Protocol::Implementation.new(name: "test-client", version: "0.0.1")
  )
  client.connect(ct)

  begin
    result = client.list_tools
    result.should_not be_nil
    if result
      result.tools.map(&.name)
    else
      [] of String
    end
  ensure
    client.close rescue nil
    transport.close rescue nil
    server.skill_library.close rescue nil
  end
end

# Port of the upstream MCP tool gating test
# Verifies capability gating: tools whose required backend isn't configured
# are not advertised so the model doesn't waste turns calling a tool that
# can only return a "not configured" error.
describe "MCP tool gating by configured capability" do
  it "always lists capability-independent tools (graph, map, verify, lint, etc.)" do
    names = build_and_list_tools
    names.should contain("chiasmus_graph")
    names.should contain("chiasmus_map")
    names.should contain("chiasmus_verify")
    names.should contain("chiasmus_lint")
    names.should contain("chiasmus_skills")
    names.should contain("chiasmus_craft")
    names.should contain("chiasmus_review")
  end

  it "keeps gracefully-degrading tools (solve, formalize) listed without an LLM" do
    names = build_and_list_tools
    names.should contain("chiasmus_solve")
    names.should contain("chiasmus_formalize")
  end

  # RED: Currently all 12 tools are listed unconditionally.
  # The upstream gates: chiasmus_learn hidden when no LLM,
  # chiasmus_search hidden when no embedding provider.
  it "hides chiasmus_learn when no LLM is configured" do
    names = build_and_list_tools
    names.should_not contain("chiasmus_learn")
  end

  it "all listed tools have valid inputSchema with type=object" do
    server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
    transport = server.build_mcp_transport
    st = MCP::Shared::InMemoryTransport.new
    ct = MCP::Shared::InMemoryTransport.new
    st.other_transport = ct
    ct.other_transport = st
    transport.connect(st)

    client = MCP::Client::Client.new(
      MCP::Protocol::Implementation.new(name: "test-client", version: "0.0.1")
    )
    client.connect(ct)

    begin
      result = client.list_tools.as(MCP::Protocol::ListToolsResult)
      result.tools.each do |tool|
        tool.name.should_not be_empty
        tool.description.should_not be_nil
        schema_json = tool.input_schema.to_json
        parsed = JSON.parse(schema_json)
        parsed["type"].as_s.should eq("object"), "Tool #{tool.name} inputSchema missing type=object"
      end
    ensure
      client.close rescue nil
      transport.close rescue nil
      server.skill_library.close rescue nil
    end
  end
end
