require "../../spec_helper"

describe Chiasmus::MCPServer::Tools::FormalizeTool do
  it "has correct tool name" do
    Chiasmus::MCPServer::Tools::FormalizeTool.tool_name.should eq("chiasmus_formalize")
  end

  it "provides a tool description" do
    Chiasmus::MCPServer::Tools::FormalizeTool.tool_description.should_not be_empty
  end

  it "declares input schema with problem as required" do
    schema = Chiasmus::MCPServer::Tools::FormalizeTool.input_schema
    schema.should_not be_nil
  end

  it "returns an error when problem is missing" do
    tool = Chiasmus::MCPServer::Tools::FormalizeTool.new
    result = tool.invoke({} of String => JSON::Any)

    result.status.should eq("error")
    result.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("problem")
  end

  it "returns an error for empty problem string" do
    tool = Chiasmus::MCPServer::Tools::FormalizeTool.new
    result = tool.invoke({
      "problem" => JSON::Any.new(""),
    })

    result.status.should eq("error")
  end

  it "returns template instructions and related suggestions for a problem" do
    server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).with_agent_builder(
      Chiasmus::LLM::MockClient.new.agent("mock")
    )
    Chiasmus::MCPServer.current_server = server
    tool = Chiasmus::MCPServer::Tools::FormalizeTool.new

    result = tool.invoke({
      "problem" => JSON::Any.new("Check if access control rules can ever conflict"),
    })

    result.status.should eq("success")
    formalize = result.as(Chiasmus::MCPServer::Types::FormalizeResponse)
    formalize.template.should eq("policy-contradiction")
    formalize.solver.should eq("z3")
    formalize.instructions.should contain("SLOT")
    suggestions = formalize.suggestions
    suggestions.should_not be_empty
    suggestions.first["name"]?.try(&.as_s?).should eq("policy-reachability")
  end

  it "uses async formalization before building the response" do
    server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).with_agent_builder(
      Chiasmus::LLM::MockClient.new.agent("mock")
    )
    Chiasmus::MCPServer.current_server = server
    tool = Chiasmus::MCPServer::Tools::FormalizeTool.new
    entered = Channel(Bool).new(1)
    release = Channel(Bool).new(1)
    result_chan = Channel(Chiasmus::MCPServer::Types::Response).new(1)

    Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).set_before_formalize_async_result_send_hook_for_test do
      entered.send(true)
      release.receive
    end

    spawn do
      result_chan.send(tool.invoke({
        "problem" => JSON::Any.new("Check if access control rules can ever conflict"),
      }))
    end

    Chiasmus::Utils::Timeout.with_timeout_async(250, entered).should eq(true)

    select
    when result_chan.receive?
      fail("expected formalize tool to wait on async response boundary")
    else
    end

    release.send(true)
    result = Chiasmus::Utils::Timeout.with_timeout_async(250, result_chan)
    result.should_not be_nil
    result.not_nil!.status.should eq("success")
  ensure
    Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).clear_before_formalize_async_result_send_hook_for_test
    Chiasmus::MCPServer.current_server = nil
  end
end
