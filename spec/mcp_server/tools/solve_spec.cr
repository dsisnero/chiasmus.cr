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

  it "uses async solve before returning the llm-backed response" do
    responses = [%( (declare-const x Int) (assert (> x 5)) ).strip]
    server = Chiasmus::MCPServer::Server(FormalizeSpecCompletionModel).with_agent_builder(
      FormalizeSpecClient.new(responses, [] of String).agent("mock")
    )
    Chiasmus::MCPServer.current_server = server
    tool = Chiasmus::MCPServer::Tools::SolveTool.new
    entered = Channel(Bool).new(1)
    release = Channel(Bool).new(1)
    result_chan = Channel(Chiasmus::MCPServer::Types::Response).new(1)

    Chiasmus::MCPServer::Server(FormalizeSpecCompletionModel).set_before_solve_async_result_send_hook_for_test do
      entered.send(true)
      release.receive
    end

    spawn do
      result_chan.send(tool.invoke({
        "problem" => JSON::Any.new("Find an integer greater than 5"),
      }))
    end

    TreeSitterManager::Timeout.with_timeout_async(250, entered).should eq(true)

    select
    when result_chan.receive?
      fail("expected solve tool to wait on async response boundary")
    else
    end

    release.send(true)
    result = TreeSitterManager::Timeout.with_timeout_async(500, result_chan)
    result.should_not be_nil
    solve_result = result || raise "expected solve tool result"
    solve_result.status.should eq("success")
  ensure
    Chiasmus::MCPServer::Server(FormalizeSpecCompletionModel).clear_before_solve_async_result_send_hook_for_test
    Chiasmus::MCPServer.current_server = nil
  end
end
