require "../../spec_helper"

describe Chiasmus::MCPServer::Tools::ReviewTool do
  it "validates raw files shape before deserializing or building a review plan" do
    tool = Chiasmus::MCPServer::Tools::ReviewTool.new

    missing = tool.invoke({} of String => JSON::Any)
    missing.status.should eq("error")
    missing.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should eq("'files' (non-empty string[]) is required")

    non_array = tool.invoke({"files" => JSON::Any.new("not-an-array")})
    non_array.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should eq("'files' (non-empty string[]) is required")

    empty = tool.invoke({"files" => JSON.parse(%([]))})
    empty.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should eq("'files' (non-empty string[]) is required")
  end

  it "rejects non-string files before review planning" do
    result = Chiasmus::MCPServer::Tools::ReviewTool.new.invoke({
      "files" => JSON.parse(%(["/abs/src/server.ts", 42, null])),
    })

    result.status.should eq("error")
    result.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should eq("'files' must contain only strings")
  end

  it "serializes suggested templates with the upstream camelCase key" do
    result = Chiasmus::MCPServer::Tools::ReviewTool.new.invoke({
      "files" => JSON.parse(%(["/abs/src/server.ts"])),
      "focus" => JSON::Any.new("security"),
    })

    result.status.should eq("success")
    serialized = JSON.parse(result.to_json)
    suggestions = serialized["suggestedTemplates"].as_a
    suggestions.should_not be_empty
    suggestions.any? { |item| item["template"].as_s == "taint-propagation" }.should be_true
    serialized["suggested_templates"]?.should be_nil

    severity_levels = serialized["reporting"]["severityLevels"].as_a.map(&.as_s)
    severity_levels.should contain("CRITICAL")
    serialized["reporting"]["severity_levels"]?.should be_nil
  end
end
