require "../../spec_helper"

describe Chiasmus::MCPServer::Tools::SolveTool do
  it "falls back to formalize when no LLM-backed formalization engine is configured" do
    server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
    Chiasmus::MCPServer.current_server = server
    tool = Chiasmus::MCPServer::Tools::SolveTool.new

    result = tool.invoke({
      "problem" => JSON::Any.new("Check if access control rules can ever conflict"),
    })

    result["status"].as_s.should eq("success")
    result["fallback"].as_bool.should be_true
    result["template"].as_s.should eq("policy-contradiction")
    result["instructions"].as_s.should contain("SLOT")
  end

  it "returns an error when problem is missing" do
    tool = Chiasmus::MCPServer::Tools::SolveTool.new
    result = tool.invoke({} of String => JSON::Any)

    result["status"].as_s.should eq("error")
    result["error"].as_s.should contain("problem")
  end
end
