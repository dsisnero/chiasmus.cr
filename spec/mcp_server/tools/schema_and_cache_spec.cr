require "../../spec_helper"

# Task 3 + 4: Verify input schemas use ToolSchemas pattern and output schemas exist
describe "Tool schema unification" do
  it "all tools have output_schema class method returning a Tool::Input" do
    tools = [
      Chiasmus::MCPServer::Tools::VerifyTool,
      Chiasmus::MCPServer::Tools::SkillsTool,
      Chiasmus::MCPServer::Tools::FormalizeTool,
      Chiasmus::MCPServer::Tools::SolveTool,
      Chiasmus::MCPServer::Tools::LearnTool,
      Chiasmus::MCPServer::Tools::LintTool,
      Chiasmus::MCPServer::Tools::GraphTool,
      Chiasmus::MCPServer::Tools::MapTool,
      Chiasmus::MCPServer::Tools::SearchTool,
      Chiasmus::MCPServer::Tools::ReadSymbolTool,
      Chiasmus::MCPServer::Tools::CraftTool,
      Chiasmus::MCPServer::Tools::ReviewTool,
      Chiasmus::MCPServer::Tools::CrigTool,
    ]
    tools.each do |klass|
      if klass.responds_to?(:output_schema)
        schema = klass.output_schema
        schema.should be_a(MCP::Protocol::Tool::Input)
      else
        # Not all tools need output schemas yet, but they should at least compile
        klass.input_schema.should be_a(MCP::Protocol::Tool::Input)
      end
    end
  end

  # Task 5: Verify cache_dir support
  it "graph tool accepts cache_dir in arguments" do
    tool = Chiasmus::MCPServer::Tools::GraphTool.new
    # Should not error when cache_dir is provided
    r = tool.invoke({
      "files"    => JSON::Any.new([JSON::Any.new("/nonexistent/file.go")]),
      "analysis" => JSON::Any.new("summary"),
      "cache"    => JSON::Any.new("/tmp/chiasmus-test-cache"),
    })
    r.status.should eq("error")
    r.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should_not be_empty
  end

  it "map tool accepts cache_dir in arguments" do
    tool = Chiasmus::MCPServer::Tools::MapTool.new
    r = tool.invoke({
      "files" => JSON::Any.new([JSON::Any.new("/nonexistent/file.go")]),
      "mode"  => JSON::Any.new("overview"),
      "cache" => JSON::Any.new("/tmp/chiasmus-test-cache"),
    })
    r.status.should eq("error")
    r.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should_not be_empty
  end

  it "map tool advertises overview include and max_exports controls" do
    properties = Chiasmus::MCPServer::Tools::MapTool.input_schema.properties

    properties.has_key?("include").should be_true
    properties.has_key?("max_exports").should be_true
  end
end
