require "../../spec_helper"
require "../../support/formalize_scripted_agent"

describe Chiasmus::MCPServer::Tools::SolveTool do
  describe ".tool_description" do
    it "documents that `converged` is not a verdict on the property" do
      desc = Chiasmus::MCPServer::Tools::SolveTool.tool_description
      desc.should match(/converged/)
      desc.should match(/result\.status/)
      desc.should match(/not.*(proof|property holds)/i)
    end
  end

  it "falls back to formalize when no LLM-backed formalization engine is configured" do
    server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
    Chiasmus::MCPServer.current_server = server
    tool = Chiasmus::MCPServer::Tools::SolveTool.new

    result = tool.invoke({
      "problem" => JSON::Any.new("Check if access control rules can ever conflict"),
    })

    result.status.should eq("success")
    resp = result.as(Chiasmus::MCPServer::Types::SolveResponse)
    resp.fallback.should be_true
    template_used = resp.template_used || raise "Expected template_used"
    template_used.should eq("policy-contradiction")
    message = resp.message || raise "Expected message"
    message.should contain("verify")
  end

  it "returns an error when problem is missing" do
    tool = Chiasmus::MCPServer::Tools::SolveTool.new
    result = tool.invoke({} of String => JSON::Any)

    result.status.should eq("error")
    result.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("problem")
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

    result.status.should eq("success")
    sr = result.as(Chiasmus::MCPServer::Types::SolveResponse)
    sr.fallback.should be_false
    sr.converged.should be_true
    sr.result.status.should eq("sat")
  end

  it "returns template used in response" do
    server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
    Chiasmus::MCPServer.current_server = server
    tool = Chiasmus::MCPServer::Tools::SolveTool.new

    result = tool.invoke({
      "problem" => JSON::Any.new("Check if two departments have overlapping access"),
    })

    result.status.should eq("success")
    resp = result.as(Chiasmus::MCPServer::Types::SolveResponse)
    template_used = resp.template_used || raise "Expected template_used"
    template_used.should_not be_empty
  end
end
