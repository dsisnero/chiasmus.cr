require "spec"
require "crig"
require "../../src/chiasmus"
require "../../src/chiasmus/llm/mock_adapter"

describe "Chiasmus Rig Integration" do
  # Mock agent for testing
  mock_agent = Chiasmus::LLM::MockAdapter.create_agent

  it "creates a chiasmus rig tool" do
    tool = Chiasmus::RigTool(Chiasmus::LLM::MockCompletionModel).new(mock_agent)

    tool.name.should eq("chiasmus")

    # Check definition
    definition = tool.definition("test")
    definition.name.should eq("chiasmus")
    definition.description.should contain("Formal verification")
    definition.parameters.should be_a(JSON::Any)
  end

  it "integrates with Crig agent" do
    # Create chiasmus agent wrapper
    chiasmus_agent = Chiasmus::ChiasmusAgent.new(mock_agent)

    # Agent wrapper should work
    chiasmus_agent.should be_a(Chiasmus::ChiasmusAgent(Chiasmus::LLM::MockCompletionModel))
  end

  it "handles errors gracefully" do
    tool = Chiasmus::RigTool(Chiasmus::LLM::MockCompletionModel).new(nil) # No agent

    result = tool.call({
      "problem" => JSON::Any.new("test"),
    })

    parsed = JSON.parse(result)
    parsed["status"].as_s.should eq("error")
    parsed["error"].as_s.should contain("LLM not available")
  end

  describe "ChiasmusAgent" do
    it "creates agent wrapper" do
      agent = Chiasmus::ChiasmusAgent.new(mock_agent)
      agent.should be_a(Chiasmus::ChiasmusAgent(Chiasmus::LLM::MockCompletionModel))
    end
  end

  it "supports factory pattern for different providers" do
    # Test that factory methods exist
    Chiasmus::MCPServer::Factory.responds_to?(:openai).should be_true
    Chiasmus::MCPServer::Factory.responds_to?(:deepseek).should be_true
    Chiasmus::MCPServer::Factory.responds_to?(:from_env).should be_true
  end
end
