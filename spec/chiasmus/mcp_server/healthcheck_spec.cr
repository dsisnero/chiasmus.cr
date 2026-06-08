require "../../spec_helper"
require "mcp"

describe "Chiasmus Healthcheck" do
  it "performs a full MCP handshake and tools/list over in-memory transport" do
    agent = Chiasmus::LLM::MockAdapter.create_agent
    chiasmus = Chiasmus::MCPServer::Server.with_agent(agent)

    begin
      result = chiasmus.healthcheck

      result[:success].should be_true
      tools = result[:tools]
      tools.should_not be_nil
      tools.not_nil!.should be > 0
      result[:version].should eq(Chiasmus::VERSION)
      result[:error]?.should be_nil
    ensure
      chiasmus.skill_library.close rescue nil
    end
  end

  it "returns success even without LLM agent (graceful degradation)" do
    chiasmus = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new

    begin
      result = chiasmus.healthcheck

      result[:success].should be_true
      result[:tools].should_not be_nil
    ensure
      chiasmus.skill_library.close rescue nil
    end
  end
end
