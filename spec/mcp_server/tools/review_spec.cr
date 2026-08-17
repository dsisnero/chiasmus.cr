require "../../spec_helper"

describe Chiasmus::MCPServer::Tools::ReviewTool do
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
  end
end
