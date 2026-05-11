require "spec"
require "mcp"
require "file_utils"
require "json"
require "../../../src/chiasmus/mcp_server/tools/graph"
require "../../../src/chiasmus/graph/types"
require "../../../src/chiasmus/graph/parser"
require "../../../src/chiasmus/graph/analyses"

describe "chiasmus_graph MCP tool" do
  temp_dir = ""
  src_dir = ""
  server : MCP::Server::Server? = nil
  client : MCP::Client::Client? = nil

  before_all do
    temp_dir = File.tempname("chiasmus-graph-test-")
    Dir.mkdir_p(temp_dir)
    src_dir = File.join(temp_dir, "src")
    Dir.mkdir_p(src_dir)

    File.write(File.join(src_dir, "server.ts"), <<-TS)
import { query } from './db';
export function handleRequest() { validate(); query(); }
function validate() {}
TS

    File.write(File.join(src_dir, "db.ts"), <<-TS)
export function query() { connect(); }
function connect() {}
function unusedHelper() {}
TS

    capabilities = MCP::Protocol::ServerCapabilities.new(
      tools: MCP::Protocol::ServerCapabilities::ToolsCapability.new(list_changed: true)
    )
    server_options = MCP::Server::ServerOptions.new(capabilities: capabilities)
    mcp_server = MCP::Server::Server.new(
      MCP::Protocol::Implementation.new(name: "test-server", version: "1.0.0"),
      server_options
    )

    tool_handler = ->(params : MCP::Protocol::CallToolRequestParams) : MCP::Protocol::CallToolResult do
      tool = Chiasmus::MCPServer::Tools::GraphTool.new
      arguments = params.arguments || {} of String => JSON::Any
      result = tool.invoke(arguments)
      content = [MCP::Protocol::TextContentBlock.new(result.to_json)] of MCP::Protocol::ContentBlock
      MCP::Protocol::CallToolResult.new(content: content)
    end

    input_schema = Chiasmus::MCPServer::Tools::GraphTool.input_schema
    mcp_server.add_tool(
      Chiasmus::MCPServer::Tools::GraphTool.tool_name,
      Chiasmus::MCPServer::Tools::GraphTool.tool_description,
      input_schema,
      &tool_handler
    )

    client_transport = MCP::Shared::InMemoryTransport.new
    server_transport = MCP::Shared::InMemoryTransport.new
    client_transport.other_transport = server_transport
    server_transport.other_transport = client_transport

    mcp_server.connect(server_transport)

    mcp_client = MCP::Client::Client.new(
      MCP::Protocol::Implementation.new(name: "test-client", version: "0.0.1")
    )
    mcp_client.connect(client_transport)

    server = mcp_server
    client = mcp_client
  end

  after_all do
    client.try(&.close)
    server.try(&.close)
    FileUtils.rm_rf(temp_dir) if Dir.exists?(temp_dir)
  end

  it "appears in tool list" do
    result = client.not_nil!.list_tools
    result.should_not be_nil
    tools = result.as(MCP::Protocol::ListToolsResult)
    names = tools.tools.map(&.name)
    names.should contain("chiasmus_graph")
  end

  it "exposes the upstream analysis allowlist in the schema and errors" do
    expected = ["summary", "callers", "callees", "reachability", "dead-code", "cycles", "path", "impact", "facts"]
    Chiasmus::MCPServer::VALID_ANALYSES.should eq(expected)

    input = Chiasmus::MCPServer::Tools::GraphTool.input_schema
    enum_values = input.properties["analysis"]["enum"].as_a.map(&.as_s)
    enum_values.should eq(expected)

    result = Chiasmus::MCPServer::Tools::GraphTool.new.invoke({
      "files"    => JSON::Any.new([JSON::Any.new(File.join(src_dir, "server.ts"))]),
      "analysis" => JSON::Any.new("unknown"),
    })
    result["error"].as_s.should contain("Use one of: #{expected.join(", ")}")
  end

  it "returns callers via MCP" do
    result = client.not_nil!.call_tool(
      "chiasmus_graph",
      {
        "files"    => JSON::Any.new([JSON::Any.new(File.join(src_dir, "server.ts")), JSON::Any.new(File.join(src_dir, "db.ts"))]),
        "analysis" => JSON::Any.new("callers"),
        "target"   => JSON::Any.new("query"),
      }
    ).as(MCP::Protocol::CallToolResult)
    content = result.content
    first_block = content.first.as(MCP::Protocol::TextContentBlock)
    parsed = JSON.parse(first_block.text)
    parsed["analysis"].should eq("callers")
    parsed["result"].to_s.should contain("handleRequest")
  end

  it "returns summary with correct counts" do
    result = client.not_nil!.call_tool(
      "chiasmus_graph",
      {
        "files"    => JSON::Any.new([JSON::Any.new(File.join(src_dir, "server.ts")), JSON::Any.new(File.join(src_dir, "db.ts"))]),
        "analysis" => JSON::Any.new("summary"),
      }
    ).as(MCP::Protocol::CallToolResult)
    content = result.content
    first_block = content.first.as(MCP::Protocol::TextContentBlock)
    parsed = JSON.parse(first_block.text)
    parsed["status"].as_s.should eq("success")
    parsed["analysis"].as_s.should eq("summary")
    parsed["result"].to_s.should contain("files")
  end

  it "returns dead code analysis" do
    result = client.not_nil!.call_tool(
      "chiasmus_graph",
      {
        "files"    => JSON::Any.new([JSON::Any.new(File.join(src_dir, "server.ts")), JSON::Any.new(File.join(src_dir, "db.ts"))]),
        "analysis" => JSON::Any.new("dead-code"),
      }
    ).as(MCP::Protocol::CallToolResult)
    content = result.content
    first_block = content.first.as(MCP::Protocol::TextContentBlock)
    parsed = JSON.parse(first_block.text)
    parsed["analysis"].should eq("dead-code")
    parsed["result"].to_s.should contain("unusedHelper")
  end

  it "returns error for missing parameters" do
    result = client.not_nil!.call_tool(
      "chiasmus_graph",
      {} of String => JSON::Any,
    ).as(MCP::Protocol::CallToolResult)
    content = result.content
    first_block = content.first.as(MCP::Protocol::TextContentBlock)
    parsed = JSON.parse(first_block.text)
    parsed["error"].should be_truthy
  end

  it "returns facts as raw Prolog" do
    result = client.not_nil!.call_tool(
      "chiasmus_graph",
      {
        "files"    => JSON::Any.new([JSON::Any.new(File.join(src_dir, "server.ts"))]),
        "analysis" => JSON::Any.new("facts"),
      }
    ).as(MCP::Protocol::CallToolResult)
    content = result.content
    first_block = content.first.as(MCP::Protocol::TextContentBlock)
    parsed = JSON.parse(first_block.text)
    parsed["analysis"].should eq("facts")
    parsed["result"].to_s.should contain("defines(")
    parsed["result"].to_s.should contain("calls(")
  end
end
