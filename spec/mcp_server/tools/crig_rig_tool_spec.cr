require "../../spec_helper"
require "json"
require "crig"

describe Chiasmus::MCPServer::Tools::CrigTool do
  it "returns ErrorResponse when prompt is missing (invoke works)" do
    tool = Chiasmus::MCPServer::Tools::CrigTool.new
    r = tool.invoke({} of String => JSON::Any)
    r.status.should eq("error")
    r.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("prompt")
  end

  it "has proper JSON schema via rig_tool auto-generation" do
    schema = Chiasmus::MCPServer::Tools::CrigTool.input_schema
    schema.properties.has_key?("prompt").should be_true
    schema.properties.has_key?("preamble").should be_true
    schema.properties.has_key?("model").should be_true
    schema.properties.has_key?("max_turns").should be_true
    (schema.required || raise "required nil").includes?("prompt").should be_true
  end

  it "returns Response type (not raw Hash)" do
    tool = Chiasmus::MCPServer::Tools::CrigTool.new
    r = tool.invoke({} of String => JSON::Any)
    r.should be_a(Chiasmus::MCPServer::Types::Response)
  end

  it "returns typed ErrorResponse on missing prompt" do
    tool = Chiasmus::MCPServer::Tools::CrigTool.new
    r = tool.invoke({} of String => JSON::Any)
    r.should be_a(Chiasmus::MCPServer::Types::ErrorResponse)
  end
end
