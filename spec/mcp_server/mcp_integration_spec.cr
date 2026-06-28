require "../spec_helper"
require "mcp"

# Comprehensive MCP protocol integration tests.
# Tests all 12 chiasmus tools through the full MCP stack:
#   InMemoryTransport → MCP::Server → MCP::Client.call_tool
#
# Plus tool gating and the in-memory healthcheck.

private def linked_transports
  server_t = MCP::Shared::InMemoryTransport.new
  client_t = MCP::Shared::InMemoryTransport.new
  server_t.other_transport = client_t
  client_t.other_transport = server_t
  {server_t, client_t}
end

private def build_mcp_server
  caps = MCP::Protocol::ServerCapabilities.new(
    tools: MCP::Protocol::ServerCapabilities::ToolsCapability.new(list_changed: true)
  )
  opts = MCP::Server::ServerOptions.new(capabilities: caps)
  impl = MCP::Protocol::Implementation.new(name: "chiasmus-test", version: "0.0.1")
  MCP::Server::Server.new(impl, opts)
end

private def register_all_tools_on(mcp_server : MCP::Server::Server)
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
    {Chiasmus::MCPServer::Tools::CrigTool, Chiasmus::MCPServer::Tools::CrigTool.tool_name, Chiasmus::MCPServer::Tools::CrigTool.tool_description, Chiasmus::MCPServer::Tools::CrigTool.input_schema},
  ]

  tools.each do |(tool_class, name, description, input_schema)|
    tool_instance = tool_class.new
    mcp_server.add_tool(name, description, input_schema) do |params|
      arguments = params.arguments || {} of String => JSON::Any
      result = tool_instance.invoke(arguments)
      json = result.to_json
      structured = begin
        JSON.parse(json).as_h
      rescue
        nil
      end
      MCP::Protocol::CallToolResult.new(
        content: [MCP::Protocol::TextContentBlock.new(json)] of MCP::Protocol::ContentBlock,
        structured_content: structured
      )
    end
  end
end

# Sets up a connected mcp_server + client pair for integration tests.
# Returns {mcp_server, client}.
private def connect_server_and_client : {MCP::Server::Server, MCP::Client::Client}
  mcp_server = build_mcp_server
  register_all_tools_on(mcp_server)

  st, ct = linked_transports
  mcp_server.connect(st)

  client = MCP::Client::Client.new(
    MCP::Protocol::Implementation.new(name: "test-client", version: "0.0.1")
  )
  client.connect(ct)

  {mcp_server, client}
end

private def disconnect(mcp_server : MCP::Server::Server, client : MCP::Client::Client)
  client.close rescue nil
  mcp_server.close rescue nil
end

private def call_tool(client : MCP::Client::Client, name : String, args : Hash(String, JSON::Any) = {} of String => JSON::Any)
  result = client.call_tool(name, args).as(MCP::Protocol::CallToolResult)
  block = result.content.first.as(MCP::Protocol::TextContentBlock)
  JSON.parse(block.text)
end

private def call_tool_async(client : MCP::Client::Client, name : String, args : Hash(String, JSON::Any) = {} of String => JSON::Any) : Channel(MCP::Protocol::CallToolResult | Exception)
  channel = Channel(MCP::Protocol::CallToolResult | Exception).new(1)

  spawn do
    begin
      result = client.call_tool(name, args).as(MCP::Protocol::CallToolResult)
      channel.send(result)
    rescue ex
      channel.send(ex)
    ensure
      channel.close
    end
  end

  channel
end

# Helper: write a temp source file and return cleanup proc + path
private def temp_source_file(ext : String, content : String) : {String, Proc(Nil)}
  dir = Dir.tempdir
  path = File.join(dir, "chiasmus-mcp-test-#{Random::Secure.hex(8)}.#{ext}")
  File.write(path, content)
  cleanup = -> { File.delete(path) if File.exists?(path) }
  {path, cleanup}
end

# =============================================================================
# MCP Server initialization and tools/list
# =============================================================================
describe "MCP async tool calls through transport" do
  it "allows one client to overlap tool calls with call_tool_async" do
    mcp_server, client = connect_server_and_client
    entered = Channel(Bool).new(2)
    release = Channel(Bool).new(2)

    Chiasmus::MCPServer::Tools::VerifyTool.set_before_async_result_send_hook_for_test do
      entered.send(true)
      release.receive
    end

    first = call_tool_async(client, "chiasmus_verify", {
      "solver" => JSON::Any.new("z3"),
      "input"  => JSON::Any.new("(declare-const x Int) (assert (> x 0))"),
    })
    second = call_tool_async(client, "chiasmus_verify", {
      "solver" => JSON::Any.new("z3"),
      "input"  => JSON::Any.new("(declare-const y Int) (assert (> y 1))"),
    })

    Chiasmus::Utils::Timeout.with_timeout_async(500, entered).should eq(true)
    Chiasmus::Utils::Timeout.with_timeout_async(500, entered).should eq(true)

    select
    when first.receive?
      fail("expected first async MCP tool call to remain blocked at verify boundary")
    when second.receive?
      fail("expected second async MCP tool call to remain blocked at verify boundary")
    else
    end

    release.send(true)
    release.send(true)

    [first, second].each do |channel|
      result = Chiasmus::Utils::Timeout.with_timeout_async(1000, channel)
      result.should_not be_nil
      raw = result || raise "expected async MCP tool result"
      raw.should be_a(MCP::Protocol::CallToolResult)
      rpc = raw.as(MCP::Protocol::CallToolResult)
      block = rpc.content.first.as(MCP::Protocol::TextContentBlock)
      JSON.parse(block.text)["status"].as_s.should eq("success")
    end
  ensure
    Chiasmus::MCPServer::Tools::VerifyTool.clear_before_async_result_send_hook_for_test
    if server = mcp_server
      if current_client = client
        disconnect(server, current_client)
      end
    end
  end
end

describe "MCP Server initialization via transport" do
  describe "initialize + tools/list" do
    it "lists all 12 expected tools" do
      mcp_server, client = connect_server_and_client
      begin
        result = client.list_tools
        result.should_not be_nil
        if r = result
          names = r.tools.map(&.name)

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
            "chiasmus_crig",
          ]
          expected.each { |tool| names.should contain(tool) }
        end
      ensure
        disconnect(mcp_server, client)
      end
    end

    it "every tool has a non-empty description and input schema with type=object" do
      mcp_server, client = connect_server_and_client
      begin
        result = client.list_tools
        result.should_not be_nil
        if r = result
          r.tools.each do |tool|
            tool.name.should_not be_empty
            tool.description.should_not be_nil
            tool.input_schema.properties.should_not be_nil
            schema_json = tool.input_schema.to_json
            parsed = JSON.parse(schema_json)
            parsed["type"]?.try(&.as_s).should eq("object"), "Tool #{tool.name} inputSchema missing type=object"
          end
        end
      ensure
        disconnect(mcp_server, client)
      end
    end

    describe "chiasmus_graph snapshot save/diff through transport" do
      it "saves snapshot via save_snapshot and cache object" do
        path, cleanup = temp_source_file("go", "package main\nfunc hello() {}")
        cache_dir = File.join(Dir.tempdir, "chiasmus-mcp-save-#{Random::Secure.hex(8)}")
        begin
          mcp_server, client = connect_server_and_client
          begin
            result = call_tool(client, "chiasmus_graph", {
              "files"         => JSON.parse([path].to_json),
              "analysis"      => JSON::Any.new("summary"),
              "save_snapshot" => JSON::Any.new("mcp-saved"),
              "cache"         => JSON.parse(%({"cache_dir": "#{cache_dir}"})),
            })
            result["status"].as_s.should eq("success")

            loaded = Chiasmus::Graph::GraphCache.load_snapshot("mcp-saved", cache_dir)
            loaded.should_not be_nil
            (loaded || raise("Expected snapshot")).defines.map(&.name).should contain("hello")
          ensure
            disconnect(mcp_server, client)
          end
        ensure
          cleanup.call
          FileUtils.rm_rf(cache_dir)
        end
      end

      it "diff against saved snapshot returns changes" do
        path, cleanup = temp_source_file("go", "package main\nfunc hello() {}")
        cache_dir = File.join(Dir.tempdir, "chiasmus-mcp-diff-#{Random::Secure.hex(8)}")
        begin
          mcp_server, client = connect_server_and_client
          begin
            # First call: save snapshot
            call_tool(client, "chiasmus_graph", {
              "files"         => JSON.parse([path].to_json),
              "analysis"      => JSON::Any.new("summary"),
              "save_snapshot" => JSON::Any.new("base"),
              "cache"         => JSON.parse(%({"cache_dir": "#{cache_dir}"})),
            })

            # Second call: diff against it
            result = call_tool(client, "chiasmus_graph", {
              "files"    => JSON.parse([path].to_json),
              "analysis" => JSON::Any.new("diff"),
              "against"  => JSON::Any.new("base"),
              "cache"    => JSON.parse(%({"cache_dir": "#{cache_dir}"})),
            })
            result["status"].as_s.should eq("success")
            result["analysis"].as_s.should eq("diff")
          ensure
            disconnect(mcp_server, client)
          end
        ensure
          cleanup.call
          FileUtils.rm_rf(cache_dir)
        end
      end
    end

    describe "chiasmus_map byte ranges through transport" do
      it "file mode returns line_end for symbols" do
        path, cleanup = temp_source_file("go", "package main\n\nfunc bar(x int) int {\n\treturn x * 2\n}\n")
        begin
          mcp_server, client = connect_server_and_client
          begin
            result = call_tool(client, "chiasmus_map", {
              "files"  => JSON.parse([path].to_json),
              "mode"   => JSON::Any.new("file"),
              "path"   => JSON::Any.new(path),
              "format" => JSON::Any.new("json"),
            })
            result["status"].as_s.should eq("success")
            content = JSON.parse(result["content"].as_s)
            symbols = content["symbols"]?.try(&.as_a)
            symbols.should_not be_nil
            if syms = symbols
              # bar function should have end_line > line
              bar = syms.find { |sym| sym["name"] == "bar" }
              bar.should_not be_nil
              if b = bar
                b["line_end"]?.try(&.as_i).try(&.should(be > b["line"].as_i))
              end
            end
          ensure
            disconnect(mcp_server, client)
          end
        ensure
          cleanup.call
        end
      end
    end
  end
end

# =============================================================================
# All 12 tools through the MCP transport layer
# =============================================================================
describe "All 12 tools through MCP transport" do
  describe "chiasmus_verify" do
    it "returns sat for Z3 tautology" do
      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_verify", {
          "solver" => JSON::Any.new("z3"),
          "input"  => JSON::Any.new("(declare-const x Int) (assert (= x x))"),
        })
        result["status"].as_s.should eq("success")
        result["result"]["status"].as_s.should eq("sat")
      ensure
        disconnect(mcp_server, client)
      end
    end

    it "returns unsat for Z3 contradiction" do
      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_verify", {
          "solver" => JSON::Any.new("z3"),
          "input"  => JSON::Any.new("(declare-const x Int) (assert (> x 10)) (assert (< x 5))"),
        })
        result["status"].as_s.should eq("success")
        result["result"]["status"].as_s.should eq("unsat")
      ensure
        disconnect(mcp_server, client)
      end
    end

    it "returns prolog answers" do
      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_verify", {
          "solver" => JSON::Any.new("prolog"),
          "input"  => JSON::Any.new("parent(tom, bob)."),
          "query"  => JSON::Any.new("parent(tom, X)."),
        })
        result["status"].as_s.should eq("success")
        answers = result["result"]["answers"]
        answers.as_a.first["bindings"]["X"].as_s.should eq("bob")
      ensure
        disconnect(mcp_server, client)
      end
    end

    it "returns error for missing parameters" do
      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_verify", {
          "solver" => JSON::Any.new("z3"),
        })
        result["status"].as_s.should eq("error")
        result["error"].as_s.should contain("input/spec")
      ensure
        disconnect(mcp_server, client)
      end
    end

    it "returns error for unknown solver" do
      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_verify", {
          "solver" => JSON::Any.new("bad"),
          "input"  => JSON::Any.new("x"),
        })
        result["status"].as_s.should eq("error")
        result["error"].as_s.should contain("Unknown solver")
      ensure
        disconnect(mcp_server, client)
      end
    end
  end

  describe "chiasmus_lint" do
    it "strips check-sat and returns cleaned spec" do
      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_lint", {
          "solver" => JSON::Any.new("z3"),
          "input"  => JSON::Any.new("(assert true)\n(check-sat)"),
        })
        result["status"].as_s.should eq("success")
        result["spec"].as_s.should eq("(assert true)")
        result["fixes"].as_a.should_not be_empty
      ensure
        disconnect(mcp_server, client)
      end
    end

    it "catches prolog missing periods" do
      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_lint", {
          "solver" => JSON::Any.new("prolog"),
          "input"  => JSON::Any.new("parent(tom, bob)\nparent(bob, ann)"),
        })
        result["status"].as_s.should eq("success")
        result["errors"].as_a.should_not be_empty
      ensure
        disconnect(mcp_server, client)
      end
    end

    it "returns error for unknown solver" do
      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_lint", {
          "solver" => JSON::Any.new("bad"),
          "input"  => JSON::Any.new("x"),
        })
        result["status"].as_s.should eq("error")
      ensure
        disconnect(mcp_server, client)
      end
    end
  end

  describe "chiasmus_skills" do
    it "lists starter templates (needs current_server)" do
      agent = Chiasmus::LLM::MockAdapter.create_agent
      server = Chiasmus::MCPServer::Server.with_agent(agent)
      Chiasmus::MCPServer.current_server = server

      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_skills")
        result["status"].as_s.should eq("success")
        result["templates"].as_a.size.should be >= 9
      ensure
        disconnect(mcp_server, client)
        server.skill_library.close rescue nil
        Chiasmus::MCPServer.current_server = nil
      end
    end

    it "returns error for nonexistent template" do
      agent = Chiasmus::LLM::MockAdapter.create_agent
      server = Chiasmus::MCPServer::Server.with_agent(agent)
      Chiasmus::MCPServer.current_server = server

      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_skills", {
          "name" => JSON::Any.new("nonexistent-template"),
        })
        result["status"].as_s.should eq("error")
        result["error"].as_s.should contain("not found")
      ensure
        disconnect(mcp_server, client)
        server.skill_library.close rescue nil
        Chiasmus::MCPServer.current_server = nil
      end
    end

    it "filters by solver type" do
      agent = Chiasmus::LLM::MockAdapter.create_agent
      server = Chiasmus::MCPServer::Server.with_agent(agent)
      Chiasmus::MCPServer.current_server = server

      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_skills", {
          "solver" => JSON::Any.new("prolog"),
        })
        result["status"].as_s.should eq("success")
        result["templates"].as_a.each do |tmpl|
          tmpl["solver"].as_s.should eq("prolog")
        end
      ensure
        disconnect(mcp_server, client)
        server.skill_library.close rescue nil
        Chiasmus::MCPServer.current_server = nil
      end
    end
  end

  describe "chiasmus_formalize" do
    it "returns error when no server is available" do
      Chiasmus::MCPServer.current_server = nil

      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_formalize", {
          "problem" => JSON::Any.new("test"),
        })
        result["status"].as_s.should eq("error")
        result["error"].as_s.should contain("Server")
      ensure
        disconnect(mcp_server, client)
        Chiasmus::MCPServer.current_server = nil
      end
    end

    it "returns template instructions with mock server" do
      server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).with_agent_builder(
        Chiasmus::LLM::MockClient.new.agent("mock")
      )
      Chiasmus::MCPServer.current_server = server

      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_formalize", {
          "problem" => JSON::Any.new("Check if access control rules can conflict"),
        })
        result["status"].as_s.should eq("success")
        result["template"].as_s.should_not be_empty
        result["solver"].as_s.should_not be_empty
        result["instructions"].as_s.should contain("SLOT")
      ensure
        disconnect(mcp_server, client)
        Chiasmus::MCPServer.current_server = nil
      end
    end
  end

  describe "chiasmus_solve" do
    it "falls back to template when no LLM" do
      server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
      Chiasmus::MCPServer.current_server = server

      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_solve", {
          "problem" => JSON::Any.new("Check if access control rules conflict"),
        })
        result["status"].as_s.should eq("success")
        result["fallback"].as_bool.should be_true
        result["template_used"].as_s.should eq("policy-contradiction")
        result["message"].as_s.should contain("verify")
      ensure
        disconnect(mcp_server, client)
        Chiasmus::MCPServer.current_server = nil
      end
    end

    it "returns error for missing problem" do
      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_solve")
        result["status"].as_s.should eq("error")
        result["error"].as_s.should contain("problem")
      ensure
        disconnect(mcp_server, client)
      end
    end
  end

  describe "chiasmus_learn" do
    it "returns error when learner is not available" do
      server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
      Chiasmus::MCPServer.current_server = server

      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_learn", {
          "solver"  => JSON::Any.new("z3"),
          "spec"    => JSON::Any.new("(assert true)"),
          "problem" => JSON::Any.new("test"),
        })
        result["status"].as_s.should eq("error")
        result["error"].as_s.should contain("LLM")
      ensure
        disconnect(mcp_server, client)
        Chiasmus::MCPServer.current_server = nil
      end
    end

    it "rejects missing parameters" do
      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_learn", {
          "solver" => JSON::Any.new("z3"),
        })
        result["status"].as_s.should eq("error")
      ensure
        disconnect(mcp_server, client)
      end
    end
  end

  describe "chiasmus_graph" do
    it "returns summary for real source file" do
      path, cleanup = temp_source_file("go", "package main\nfunc main() { helper() }\nfunc helper() {}")
      begin
        mcp_server, client = connect_server_and_client
        begin
          result = call_tool(client, "chiasmus_graph", {
            "files"    => JSON.parse([path].to_json),
            "analysis" => JSON::Any.new("summary"),
          })
          result["status"].as_s.should eq("success")
          result["analysis"].as_s.should eq("summary")
        ensure
          disconnect(mcp_server, client)
        end
      ensure
        cleanup.call
      end
    end

    it "returns error for missing files" do
      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_graph", {
          "analysis" => JSON::Any.new("summary"),
        })
        result["status"].as_s.should eq("error")
        result["error"].as_s.should contain("files")
      ensure
        disconnect(mcp_server, client)
      end
    end

    it "returns error for unknown analysis" do
      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_graph", {
          "files"    => JSON.parse(["/nonexistent"].to_json),
          "analysis" => JSON::Any.new("bad"),
        })
        result["status"].as_s.should eq("error")
        result["error"].as_s.should contain("Unknown analysis")
      ensure
        disconnect(mcp_server, client)
      end
    end
  end

  describe "chiasmus_map" do
    it "returns overview for source file" do
      path, cleanup = temp_source_file("go", "package main\nfunc main() { helper() }\nfunc helper() {}")
      begin
        mcp_server, client = connect_server_and_client
        begin
          result = call_tool(client, "chiasmus_map", {
            "files" => JSON.parse([path].to_json),
            "mode"  => JSON::Any.new("overview"),
          })
          result["status"].as_s.should eq("success")
          result["content"].as_s.should_not be_empty
        ensure
          disconnect(mcp_server, client)
        end
      ensure
        cleanup.call
      end
    end

    it "returns error for empty files" do
      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_map", {
          "files" => JSON.parse(%([])),
        })
        result["status"].as_s.should eq("error")
      ensure
        disconnect(mcp_server, client)
      end
    end
  end

  describe "chiasmus_review" do
    it "returns review plan for source file" do
      path, cleanup = temp_source_file("go", "package main\nfunc main() { helper() }\nfunc helper() {}")
      begin
        mcp_server, client = connect_server_and_client
        begin
          result = call_tool(client, "chiasmus_review", {
            "files" => JSON.parse([path].to_json),
            "focus" => JSON::Any.new("quick"),
          })
          result["status"].as_s.should eq("success")
          result["focus"].as_s.should eq("quick")
          result["phases"].as_a.should_not be_empty
        ensure
          disconnect(mcp_server, client)
        end
      ensure
        cleanup.call
      end
    end

    it "returns error for empty files" do
      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_review", {
          "files" => JSON.parse(%([])),
        })
        result["status"].as_s.should eq("error")
      ensure
        disconnect(mcp_server, client)
      end
    end
  end

  describe "chiasmus_craft" do
    it "creates and then finds a template via skills search" do
      dir = File.join(Dir.tempdir, "chiasmus-mcp-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(dir)
      begin
        with_env({"CHIASMUS_HOME" => dir}) do
          agent = Chiasmus::LLM::MockAdapter.create_agent
          server = Chiasmus::MCPServer::Server.with_agent(agent)
          Chiasmus::MCPServer.current_server = server

          mcp_server, client = connect_server_and_client
          begin
            craft_args = {
              "name"           => JSON::Any.new("mcp-test-template"),
              "domain"         => JSON::Any.new("validation"),
              "solver"         => JSON::Any.new("z3"),
              "signature"      => JSON::Any.new("MCP integration test"),
              "skeleton"       => JSON::Any.new("(assert {{SLOT:x}})"),
              "slots"          => JSON.parse(%([{"name":"x","description":"desc","format":"fmt"}])),
              "normalizations" => JSON.parse(%([{"source":"s","transform":"t"}])),
            }
            result = call_tool(client, "chiasmus_craft", craft_args)
            result["status"].as_s.should eq("success")
            result["created"].as_bool.should be_true

            result = call_tool(client, "chiasmus_skills", {
              "query" => JSON::Any.new("validation"),
            })
            result["status"].as_s.should eq("success")
            names = result["templates"].as_a.map(&.["name"].as_s)
            names.should contain("mcp-test-template")
          ensure
            disconnect(mcp_server, client)
            server.skill_library.close rescue nil
            Chiasmus::MCPServer.current_server = nil
          end
        end
      ensure
        FileUtils.rm_rf(dir) if Dir.exists?(dir)
      end
    end

    it "rejects duplicate template name" do
      dir = File.join(Dir.tempdir, "chiasmus-mcp-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(dir)
      begin
        with_env({"CHIASMUS_HOME" => dir}) do
          agent = Chiasmus::LLM::MockAdapter.create_agent
          server = Chiasmus::MCPServer::Server.with_agent(agent)
          Chiasmus::MCPServer.current_server = server

          mcp_server, client = connect_server_and_client
          begin
            args = {
              "name"           => JSON::Any.new("dup-mcp-template"),
              "domain"         => JSON::Any.new("validation"),
              "solver"         => JSON::Any.new("z3"),
              "signature"      => JSON::Any.new("dup test"),
              "skeleton"       => JSON::Any.new("(assert {{SLOT:x}})"),
              "slots"          => JSON.parse(%([{"name":"x","description":"desc","format":"fmt"}])),
              "normalizations" => JSON.parse(%([{"source":"s","transform":"t"}])),
            }
            call_tool(client, "chiasmus_craft", args)
            result = call_tool(client, "chiasmus_craft", args)
            result["status"].as_s.should eq("success")
            result["created"].as_bool.should be_false
          ensure
            disconnect(mcp_server, client)
            server.skill_library.close rescue nil
            Chiasmus::MCPServer.current_server = nil
          end
        end
      ensure
        FileUtils.rm_rf(dir) if Dir.exists?(dir)
      end
    end
  end

  describe "chiasmus_crig" do
    it "returns error for missing prompt" do
      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_crig")
        result["status"].as_s.should eq("error")
        result["error"].as_s.should contain("prompt")
      ensure
        disconnect(mcp_server, client)
      end
    end
  end

  describe "chiasmus_search" do
    it "returns error for missing query" do
      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_search", {
          "files" => JSON.parse(%([])),
        })
        result["status"].as_s.should eq("error")
        result["error"].as_s.should contain("query")
      ensure
        disconnect(mcp_server, client)
      end
    end

    it "returns error for missing files" do
      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_search", {
          "query" => JSON::Any.new("test"),
        })
        result["status"].as_s.should eq("error")
        result["error"].as_s.should contain("files")
      ensure
        disconnect(mcp_server, client)
      end
    end
  end
end

# =============================================================================
# Server#healthcheck - in-memory MCP healthcheck
# =============================================================================
describe "Server#healthcheck" do
  it "returns success with tool count when tools are registered" do
    agent = Chiasmus::LLM::MockAdapter.create_agent
    server = Chiasmus::MCPServer::Server.with_agent(agent)
    begin
      result = server.healthcheck
      result[:success].should be_true, "Healthcheck failed: #{result[:error]}"
      result[:version].should eq(Chiasmus::VERSION)
      result[:error].should be_nil

      tools = result[:tools]
      tools.should_not be_nil, "Expected tools count, got nil"
      if t = tools
        t.should be >= 11
      end
    ensure
      server.skill_library.close rescue nil
    end
  end
end

# =============================================================================
# Tool gating: chiasmus_learn hidden when no LLM configured
# =============================================================================
describe "Tool gating by configured capability" do
  it "chiasmus_learn is hidden when no LLM is configured" do
    server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
    transport = server.build_mcp_transport

    st, ct = linked_transports
    transport.connect(st)

    client = MCP::Client::Client.new(
      MCP::Protocol::Implementation.new(name: "test-client", version: "0.0.1")
    )
    client.connect(ct)

    begin
      result = client.list_tools
      result.should_not be_nil
      if r = result
        names = r.tools.map(&.name)
        names.should_not contain("chiasmus_learn")
      end
    ensure
      client.close rescue nil
      transport.close rescue nil
      server.skill_library.close rescue nil
    end
  end

  it "always lists llm-independent tools" do
    server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
    transport = server.build_mcp_transport

    st, ct = linked_transports
    transport.connect(st)

    client = MCP::Client::Client.new(
      MCP::Protocol::Implementation.new(name: "test-client", version: "0.0.1")
    )
    client.connect(ct)

    begin
      result = client.list_tools
      result.should_not be_nil
      if r = result
        names = r.tools.map(&.name)

        names.should contain("chiasmus_verify")
        names.should contain("chiasmus_skills")
        names.should contain("chiasmus_lint")
        names.should contain("chiasmus_graph")
        names.should contain("chiasmus_map")
        names.should contain("chiasmus_craft")
        names.should contain("chiasmus_review")
        names.should contain("chiasmus_formalize")
        names.should contain("chiasmus_solve")
      end
    ensure
      client.close rescue nil
      transport.close rescue nil
      server.skill_library.close rescue nil
    end
  end
end

# =============================================================================
# Structured content on CallToolResult
# =============================================================================
describe "CallToolResult structured_content" do
  it "includes structured_content with status field" do
    mcp_server, client = connect_server_and_client
    begin
      result = client.call_tool("chiasmus_verify", {
        "solver" => JSON::Any.new("z3"),
        "input"  => JSON::Any.new("(declare-const x Int) (assert (= x x))"),
      }).as(MCP::Protocol::CallToolResult)

      structured = result.structured_content
      structured.should_not be_nil
      if structured
        structured["status"].as_s.should eq("success")
      end
    ensure
      disconnect(mcp_server, client)
    end
  end

  it "includes structured_content with error status on failure" do
    mcp_server, client = connect_server_and_client
    begin
      result = client.call_tool("chiasmus_verify", {
        "solver" => JSON::Any.new("z3"),
      }).as(MCP::Protocol::CallToolResult)

      structured = result.structured_content
      structured.should_not be_nil
      if structured
        structured["status"].as_s.should eq("error")
      end
    ensure
      disconnect(mcp_server, client)
    end
  end
end

# =============================================================================
# Unknown tool call — verify server doesn't crash on unknown tool names
# =============================================================================
describe "Unknown tool handling" do
  it "tool listing does not include unknown tools" do
    mcp_server, client = connect_server_and_client
    begin
      result = client.list_tools
      result.should_not be_nil
      if r = result
        names = r.tools.map(&.name)
        names.should_not contain("chiasmus_nonexistent")
      end
    ensure
      disconnect(mcp_server, client)
    end
  end
end

describe "full pipeline: graph facts to prolog verify" do
  it "queries graph facts via chiasmus_verify Prolog" do
    path, cleanup = temp_source_file("go", "package main
func hello() {}
func main() { hello() }
")
    begin
      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_graph", {
          "files"    => JSON.parse([path].to_json),
          "analysis" => JSON::Any.new("facts"),
        })
        result["status"].as_s.should eq("success")

        prolog = result["result"].as_s
        verify = call_tool(client, "chiasmus_verify", {
          "solver" => JSON::Any.new("prolog"),
          "spec"   => JSON::Any.new(prolog),
          "query"  => JSON::Any.new("caller_of(hello, Who)."),
        })
        verify["status"].as_s.should eq("success")
      ensure
        disconnect(mcp_server, client)
      end
    ensure
      cleanup.call
    end
  end

  it "snapshot save then diff detects changes via transport" do
    path, cleanup = temp_source_file("go", "package main
func hello() {}
")
    cache_dir = File.join(Dir.tempdir, "chiasmus-pipe-#{Random::Secure.hex(8)}")
    begin
      mcp_server, client = connect_server_and_client
      begin
        save = call_tool(client, "chiasmus_graph", {
          "files"         => JSON.parse([path].to_json),
          "analysis"      => JSON::Any.new("summary"),
          "save_snapshot" => JSON::Any.new("v1"),
          "cache"         => JSON.parse(%({"cache_dir": "#{cache_dir}"})),
        })
        save["status"].as_s.should eq("success")

        diff = call_tool(client, "chiasmus_graph", {
          "files"    => JSON.parse([path].to_json),
          "analysis" => JSON::Any.new("diff"),
          "against"  => JSON::Any.new("v1"),
          "cache"    => JSON.parse(%({"cache_dir": "#{cache_dir}"})),
        })
        diff["status"].as_s.should eq("success")
        diff["analysis"].as_s.should eq("diff")
      ensure
        disconnect(mcp_server, client)
      end
    ensure
      cleanup.call
      FileUtils.rm_rf(cache_dir)
    end
  end

  describe "chiasmus_graph structural analyses through transport" do
    it "dead-code finds unreachable functions" do
      path, cleanup = temp_source_file("go", "package main\nfunc reachable() {}\nfunc unreachable() {}\nfunc main() { reachable() }\n")
      begin
        mcp_server, client = connect_server_and_client
        begin
          result = call_tool(client, "chiasmus_graph", {
            "files"    => JSON.parse([path].to_json),
            "analysis" => JSON::Any.new("dead-code"),
          })
          result["status"].as_s.should eq("success")
        ensure
          disconnect(mcp_server, client)
        end
      ensure
        cleanup.call
      end
    end

    it "callers returns functions that call the target" do
      path, cleanup = temp_source_file("go", "package main\nfunc main() { helper() }\nfunc helper() {}\n")
      begin
        mcp_server, client = connect_server_and_client
        begin
          result = call_tool(client, "chiasmus_graph", {
            "files"    => JSON.parse([path].to_json),
            "analysis" => JSON::Any.new("callers"),
            "target"   => JSON::Any.new("helper"),
          })
          result["status"].as_s.should eq("success")
        ensure
          disconnect(mcp_server, client)
        end
      ensure
        cleanup.call
      end
    end

    it "paths finds call chain between functions" do
      path, cleanup = temp_source_file("go", "package main\nfunc a() { b() }\nfunc b() { c() }\nfunc c() {}\n")
      begin
        mcp_server, client = connect_server_and_client
        begin
          result = call_tool(client, "chiasmus_graph", {
            "files"    => JSON.parse([path].to_json),
            "analysis" => JSON::Any.new("path"),
            "from"     => JSON::Any.new("a"),
            "to"       => JSON::Any.new("c"),
          })
          result["status"].as_s.should eq("success")
        ensure
          disconnect(mcp_server, client)
        end
      ensure
        cleanup.call
      end
    end
  end
  describe "chiasmus_verify batch queries through transport" do
    it "runs multiple Prolog queries against the same program" do
      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_verify", {
          "solver"  => JSON::Any.new("prolog"),
          "spec"    => JSON::Any.new("edge(a,b). edge(b,c)."),
          "queries" => JSON.parse(%(["edge(a,X).", "edge(b,X)."])),
        })
        result["status"].as_s.should eq("success")
      ensure
        disconnect(mcp_server, client)
      end
    end

    it "rejects non-string array elements in queries" do
      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_verify", {
          "solver"  => JSON::Any.new("prolog"),
          "spec"    => JSON::Any.new("edge(a,b)."),
          "queries" => JSON.parse(%(["edge(a,X).", 42])),
        })
        result["status"].as_s.should eq("error")
      ensure
        disconnect(mcp_server, client)
      end
    end

    it "returns error for empty queries array" do
      mcp_server, client = connect_server_and_client
      begin
        result = call_tool(client, "chiasmus_verify", {
          "solver"  => JSON::Any.new("prolog"),
          "spec"    => JSON::Any.new("edge(a,b)."),
          "queries" => JSON.parse(%([])),
        })
        result["status"].as_s.should eq("error")
      ensure
        disconnect(mcp_server, client)
      end
    end
  end
end
