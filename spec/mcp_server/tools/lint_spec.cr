require "../../spec_helper"

describe Chiasmus::MCPServer::Tools::LintTool do
  it "requires solver and input parameters" do
    tool = Chiasmus::MCPServer::Tools::LintTool.new

    result = tool.invoke({"input" => JSON::Any.new("test")})
    result["status"].as_s.should eq("error")
    result["error"].as_s.should_not be_empty

    result = tool.invoke({"solver" => JSON::Any.new("z3")})
    result["status"].as_s.should eq("error")
    result["error"].as_s.should_not be_empty
  end

  it "rejects unknown solver values" do
    tool = Chiasmus::MCPServer::Tools::LintTool.new

    result = tool.invoke({
      "solver" => JSON::Any.new("unknown"),
      "input"  => JSON::Any.new("(assert true)"),
    })

    result["status"].as_s.should eq("error")
    result["error"].as_s.should contain("Unknown solver")
  end

  it "returns the linted z3 spec and applied fixes" do
    tool = Chiasmus::MCPServer::Tools::LintTool.new

    result = tool.invoke({
      "solver" => JSON::Any.new("z3"),
      "input"  => JSON::Any.new("```smt\n(assert true)\n(check-sat)\n```"),
    })

    result["status"].as_s.should eq("success")
    result["spec"].as_s.should eq("(assert true)")
    result["fixes"].as_a.size.should be >= 1
    result["errors"].as_a.should be_empty
  end

  it "returns structural prolog errors without crashing" do
    tool = Chiasmus::MCPServer::Tools::LintTool.new

    result = tool.invoke({
      "solver" => JSON::Any.new("prolog"),
      "input"  => JSON::Any.new("parent(tom, bob)\nparent(bob, ann)"),
    })

    result["status"].as_s.should eq("success")
    result["errors"].as_a.should_not be_empty
    result["errors"].as_a.first.as_s.should match(/period/i)
  end
end
