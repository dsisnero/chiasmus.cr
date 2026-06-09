require "../../spec_helper"

describe "Tool output schemas" do
  it "VerifyTool has output_schema" do
    Chiasmus::MCPServer::Tools::VerifyTool.responds_to?(:output_schema).should be_true
  end
  it "SkillsTool has output_schema" do
    Chiasmus::MCPServer::Tools::SkillsTool.responds_to?(:output_schema).should be_true
  end
  it "FormalizeTool has output_schema" do
    Chiasmus::MCPServer::Tools::FormalizeTool.responds_to?(:output_schema).should be_true
  end
  it "SolveTool has output_schema" do
    Chiasmus::MCPServer::Tools::SolveTool.responds_to?(:output_schema).should be_true
  end
  it "LearnTool has output_schema" do
    Chiasmus::MCPServer::Tools::LearnTool.responds_to?(:output_schema).should be_true
  end
  it "LintTool has output_schema" do
    Chiasmus::MCPServer::Tools::LintTool.responds_to?(:output_schema).should be_true
  end
  it "GraphTool has output_schema" do
    Chiasmus::MCPServer::Tools::GraphTool.responds_to?(:output_schema).should be_true
  end
  it "MapTool has output_schema" do
    Chiasmus::MCPServer::Tools::MapTool.responds_to?(:output_schema).should be_true
  end
  it "SearchTool has output_schema" do
    Chiasmus::MCPServer::Tools::SearchTool.responds_to?(:output_schema).should be_true
  end
  it "CraftTool has output_schema" do
    Chiasmus::MCPServer::Tools::CraftTool.responds_to?(:output_schema).should be_true
  end
  it "ReviewTool has output_schema" do
    Chiasmus::MCPServer::Tools::ReviewTool.responds_to?(:output_schema).should be_true
  end
  it "CrigTool has output_schema" do
    Chiasmus::MCPServer::Tools::CrigTool.responds_to?(:output_schema).should be_true
  end
end
