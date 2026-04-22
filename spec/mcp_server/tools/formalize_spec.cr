require "../../spec_helper"

describe Chiasmus::MCPServer::Tools::FormalizeTool do
  it "returns template instructions and related suggestions for a problem" do
    server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).with_agent_builder(
      Chiasmus::LLM::MockClient.new.agent("mock")
    )
    Chiasmus::MCPServer.current_server = server
    tool = Chiasmus::MCPServer::Tools::FormalizeTool.new

    result = tool.invoke({
      "problem" => JSON::Any.new("Check if access control rules can ever conflict"),
    })

    result["status"].as_s.should eq("success")
    result["template"].as_s.should eq("policy-contradiction")
    result["solver"].as_s.should eq("z3")
    result["instructions"].as_s.should contain("SLOT")
    suggestions = result["suggestions"].as_a
    suggestions.should_not be_empty
    suggestions.first.as_h["name"].as_s.should eq("policy-reachability")
  end

  it "returns an error when problem is missing" do
    tool = Chiasmus::MCPServer::Tools::FormalizeTool.new
    result = tool.invoke({} of String => JSON::Any)

    result["status"].as_s.should eq("error")
    result["error"].as_s.should contain("problem")
  end
end
