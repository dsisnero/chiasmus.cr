require "../../spec_helper"

private macro as_lint(result)
  result.as(Chiasmus::MCPServer::Types::LintResponse)
end

describe Chiasmus::MCPServer::Tools::LintTool do
  it "requires solver and input parameters" do
    tool = Chiasmus::MCPServer::Tools::LintTool.new

    result = tool.invoke({"input" => JSON::Any.new("test")})
    result.status.should eq("error")
    result.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should_not be_empty

    result = tool.invoke({"solver" => JSON::Any.new("z3")})
    result.status.should eq("error")
    result.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should_not be_empty
  end

  it "rejects unknown solver values" do
    tool = Chiasmus::MCPServer::Tools::LintTool.new

    result = tool.invoke({
      "solver" => JSON::Any.new("unknown"),
      "input"  => JSON::Any.new("(assert true)"),
    })

    result.status.should eq("error")
    result.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("Unknown solver")
  end

  it "returns the linted z3 spec and applied fixes" do
    tool = Chiasmus::MCPServer::Tools::LintTool.new

    result = tool.invoke({
      "solver" => JSON::Any.new("z3"),
      "input"  => JSON::Any.new("```smt\n(assert true)\n(check-sat)\n```"),
    })

    result.status.should eq("success")
    lint = as_lint(result)
    lint.spec.should eq("(assert true)")
    lint.fixes.size.should be >= 1
    lint.errors.should be_empty
  end

  it "returns structural prolog errors without crashing" do
    tool = Chiasmus::MCPServer::Tools::LintTool.new

    result = tool.invoke({
      "solver" => JSON::Any.new("prolog"),
      "input"  => JSON::Any.new("parent(tom, bob)\nparent(bob, ann)"),
    })

    result.status.should eq("success")
    lint = as_lint(result)
    lint.errors.should_not be_empty
    lint.errors.first.should match(/period/i)
  end

  it "catches unbalanced parentheses in Z3 specs" do
    tool = Chiasmus::MCPServer::Tools::LintTool.new

    result = tool.invoke({
      "solver" => JSON::Any.new("z3"),
      "input"  => JSON::Any.new("(assert (> x 0)"),
    })

    result.status.should eq("success")
    as_lint(result).errors.should_not be_empty
  end

  it "removes get-model from Z3 specs" do
    tool = Chiasmus::MCPServer::Tools::LintTool.new

    result = tool.invoke({
      "solver" => JSON::Any.new("z3"),
      "input"  => JSON::Any.new("(assert true)\n(get-model)"),
    })

    result.status.should eq("success")
    as_lint(result).spec.should_not contain("get-model")
  end

  it "removes set-logic from Z3 specs" do
    tool = Chiasmus::MCPServer::Tools::LintTool.new

    result = tool.invoke({
      "solver" => JSON::Any.new("z3"),
      "input"  => JSON::Any.new("(set-logic QF_LIA)\n(assert (> x 0))"),
    })

    result.status.should eq("success")
    as_lint(result).spec.should_not contain("set-logic")
  end

  it "passes clean Z3 spec with no errors or fixes" do
    tool = Chiasmus::MCPServer::Tools::LintTool.new

    result = tool.invoke({
      "solver" => JSON::Any.new("z3"),
      "input"  => JSON::Any.new("(declare-const x Int)\n(assert (> x 0))"),
    })

    result.status.should eq("success")
    lint = as_lint(result)
    lint.fixes.should be_empty
    lint.errors.should be_empty
  end

  it "catches unfilled template slots in Z3 specs" do
    tool = Chiasmus::MCPServer::Tools::LintTool.new

    result = tool.invoke({
      "solver" => JSON::Any.new("z3"),
      "input"  => JSON::Any.new("{{SLOT:condition}}"),
    })

    as_lint(result).errors.should_not be_empty
  end

  it "catches empty spec" do
    tool = Chiasmus::MCPServer::Tools::LintTool.new

    result = tool.invoke({
      "solver" => JSON::Any.new("z3"),
      "input"  => JSON::Any.new(""),
    })

    as_lint(result).errors.should_not be_empty
  end
end
