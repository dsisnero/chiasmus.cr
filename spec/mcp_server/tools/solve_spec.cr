require "../../spec_helper"
require "../../support/formalize_scripted_agent"

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

  it "runs the llm-backed solve path when the server has an agent" do
    responses = [%( (declare-const x Int) (assert (> x 5)) ).strip]
    server = Chiasmus::MCPServer::Server(FormalizeSpecCompletionModel).with_agent_builder(
      FormalizeSpecClient.new(responses, [] of String).agent("mock")
    )
    Chiasmus::MCPServer.current_server = server
    tool = Chiasmus::MCPServer::Tools::SolveTool.new

    result = tool.invoke({
      "problem" => JSON::Any.new("Find an integer greater than 5"),
    })

    result["status"].as_s.should eq("success")
    result["fallback"].as_bool.should be_false
    result["converged"].as_bool.should be_true
    result["result"].as_h["status"].as_s.should eq("sat")
  end
end
