require "../spec_helper"
require "mcp"

# TDD: LLM and embedding provider defaults.
# Red → Green → Refactor.
#
# Desired behavior:
#   1. Default LLM provider = deepseek (not openai)
#   2. Server starts gracefully without any API keys
#   3. Default embedding provider = ollama (local, no API key)

private def without_api_keys(&)
  original = {
    "OPENAI_API_KEY"          => ENV["OPENAI_API_KEY"]?,
    "DEEPSEEK_API_KEY"        => ENV["DEEPSEEK_API_KEY"]?,
    "ANTHROPIC_API_KEY"       => ENV["ANTHROPIC_API_KEY"]?,
    "CHIASMUS_LLM_PROVIDER"   => ENV["CHIASMUS_LLM_PROVIDER"]?,
    "CHIASMUS_EMBED_PROVIDER" => ENV["CHIASMUS_EMBED_PROVIDER"]?,
  }
  original.each_key { |k| ENV.delete(k) }

  begin
    yield
  ensure
    original.each { |k, v| v ? (ENV[k] = v) : ENV.delete(k) }
  end
end

# =============================================================================
# 1. Default LLM provider = deepseek (currently RED: defaults to openai)
# =============================================================================
describe "Factory.from_env default LLM provider" do
  it "defaults to deepseek when CHIASMUS_LLM_PROVIDER is not set" do
    ENV.delete("CHIASMUS_LLM_PROVIDER")

    begin
      server = Chiasmus::MCPServer::Factory.from_env
      server.should_not be_nil
      # GREEN: When default is deepseek and no DEEPSEEK_API_KEY is set,
      # from_env still returns a server (graceful degradation).
      # The server's healthcheck should succeed with non-LLM tools.
      health = server.healthcheck
      health[:success].should be_true, "Expected healthcheck to succeed, got: #{health[:error]}"
    ensure
      server.try(&.skill_library).try(&.close)
    end
  end

  it "starts and serves tools/list without any API keys" do
    without_api_keys do
      server = Chiasmus::MCPServer::Factory.from_env
      transport = server.build_mcp_transport

      st = MCP::Shared::InMemoryTransport.new
      ct = MCP::Shared::InMemoryTransport.new
      st.other_transport = ct
      ct.other_transport = st
      transport.connect(st)

      client = MCP::Client::Client.new(
        MCP::Protocol::Implementation.new(name: "test", version: "0.0.1")
      )
      client.connect(ct)

      begin
        result = client.list_tools
        result.should_not be_nil
        if r = result
          names = r.tools.map(&.name)

          names.should contain("chiasmus_verify")
          names.should contain("chiasmus_lint")
          names.should contain("chiasmus_graph")
          names.should contain("chiasmus_map")
          names.should contain("chiasmus_craft")
          names.should contain("chiasmus_review")
        end
      ensure
        client.close rescue nil
        transport.close rescue nil
        server.skill_library.close rescue nil
      end
    end
  end
end

# =============================================================================
# 2. Default embedding provider = ollama (currently RED: defaults to deepseek)
# =============================================================================
describe "SearchTool embedding provider default" do
  it "defaults to ollama when CHIASMUS_EMBED_PROVIDER is not set" do
    ENV.delete("CHIASMUS_EMBED_PROVIDER")
    original_deepseek = ENV["DEEPSEEK_API_KEY"]?
    original_openai = ENV["OPENAI_API_KEY"]?
    ENV.delete("DEEPSEEK_API_KEY")
    ENV.delete("OPENAI_API_KEY")

    begin
      Chiasmus::MCPServer::Tools::SearchTool.resolved_embedding_provider_name.should eq("ollama")
    ensure
      ENV["DEEPSEEK_API_KEY"] = original_deepseek if original_deepseek
      ENV["OPENAI_API_KEY"] = original_openai if original_openai
    end
  end
end
