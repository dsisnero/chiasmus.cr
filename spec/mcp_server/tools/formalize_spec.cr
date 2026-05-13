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

    result["status"].as_s.should eq("error")
    result["error"].as_s.should contain("problem")
  end

  it "returns an error for empty problem string" do
    tool = Chiasmus::MCPServer::Tools::FormalizeTool.new
    result = tool.invoke({
      "problem" => JSON::Any.new(""),
    })

    result["status"].as_s.should eq("error")
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

    result["status"].as_s.should eq("success")
    result["template"].as_s.should eq("policy-contradiction")
    result["solver"].as_s.should eq("z3")
    result["instructions"].as_s.should contain("SLOT")
    suggestions = result["suggestions"].as_a
    suggestions.should_not be_empty
    suggestions.first.as_h["name"].as_s.should eq("policy-reachability")
  end
end
