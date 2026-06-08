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

    result.status.should eq("success")
    result.as(Chiasmus::MCPServer::Types::SolveResponse).fallback.should be_true
    result.as(Chiasmus::MCPServer::Types::SolveResponse).template_used.not_nil!.should eq("policy-contradiction")
    result.as(Chiasmus::MCPServer::Types::SolveResponse).message.not_nil!.should contain("verify")
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
    result.as(Chiasmus::MCPServer::Types::SolveResponse).template_used.not_nil!.should_not be_empty
  end
end
