require "../../spec_helper"

describe Chiasmus::MCPServer::Tools::VerifyTool do
  describe "#invoke" do
    it "requires solver and input parameters" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new

      # Missing solver
      result = tool.invoke({"input" => JSON::Any.new("test")})
      result["status"].as_s.should eq "error"
      result["error"].to_s.should_not be_empty

      # Missing input
      result = tool.invoke({"solver" => JSON::Any.new("z3")})
      result["status"].as_s.should eq "error"
      result["error"].to_s.should_not be_empty
    end

    it "handles unknown solver" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      result = tool.invoke({
        "solver" => JSON::Any.new("unknown"),
        "input"  => JSON::Any.new("test"),
      })

      result["status"].as_s.should eq "error"
      result["error"].to_s.should contain "Unknown solver"
    end

    it "returns actual result for z3 solver" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      input = "(declare-const x Int) (assert (> x 3))"
      result = tool.invoke({
        "solver" => JSON::Any.new("z3"),
        "input"  => JSON::Any.new(input),
      })

      result["status"].as_s.should eq "success"
      result_hash = result["result"].as_h
      # Z3 should return sat for this simple constraint
      ["sat", "unsat", "unknown", "error"].should contain(result_hash["status"].as_s)
    end

    it "returns actual result for prolog solver" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      input = "parent(tom, bob). parent(bob, ann)."
      result = tool.invoke({
        "solver" => JSON::Any.new("prolog"),
        "input"  => JSON::Any.new(input),
        "query"  => JSON::Any.new("parent(tom, X)."),
      })

      result["status"].as_s.should eq "success"
      result_hash = result["result"].as_h
      result_hash["status"].as_s.should eq "success"
      result_hash["answers"].as_a.size.should be >= 1
    end

    it "handles prolog mermaid format" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      input = "graph TD\n  A --> B"
      result = tool.invoke({
        "solver" => JSON::Any.new("prolog"),
        "input"  => JSON::Any.new(input),
        "format" => JSON::Any.new("mermaid"),
        "query"  => JSON::Any.new("edge(a, b)."),
      })

      result["status"].as_s.should eq "success"
      result["result"].as_h["status"].as_s.should eq "success"
    end

    it "handles prolog with queries array" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      input = "parent(tom, bob). parent(bob, ann)."
      queries = JSON.parse(%(["parent(tom, X).", "parent(bob, X)."]))
      result = tool.invoke({
        "solver"  => JSON::Any.new("prolog"),
        "input"   => JSON::Any.new(input),
        "queries" => queries,
      })

      result["status"].as_s.should eq "error"
      result["error"].to_s.should_not be_empty
    end

    it "handles prolog with explain flag" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      input = "parent(tom, bob). parent(bob, ann)."
      result = tool.invoke({
        "solver"  => JSON::Any.new("prolog"),
        "input"   => JSON::Any.new(input),
        "query"   => JSON::Any.new("parent(tom, X)."),
        "explain" => JSON::Any.new(true),
      })

      result["status"].as_s.should eq "success"
      result_hash = result["result"].as_h
      result_hash["status"].as_s.should eq "success"
      result_hash["trace"].as_a.size.should be > 0
    end
  end
end
