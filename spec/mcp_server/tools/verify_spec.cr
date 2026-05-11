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
      result_hash["status"].as_s.should eq "sat"
      result_hash["model"].as_h.keys.should contain("x")
    end

    it "verifies unsatisfiable Z3 input" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      input = "(declare-const x Int) (assert (> x 10)) (assert (< x 5))"
      result = tool.invoke({
        "solver" => JSON::Any.new("z3"),
        "input"  => JSON::Any.new(input),
      })

      result["status"].as_s.should eq "success"
      result_hash = result["result"].as_h
      result_hash["status"].as_s.should eq "unsat"
    end

    it "returns structured error for malformed Z3 input" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      input = %{(declare-const x Int) (assert (> x "bad"))}
      result = tool.invoke({
        "solver" => JSON::Any.new("z3"),
        "input"  => JSON::Any.new(input),
      })

      result["status"].as_s.should eq "success"
      result_hash = result["result"].as_h
      result_hash["status"].as_s.should eq "error"
      result_hash["error"].to_s.should_not be_empty
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
      bindings = result_hash["answers"].as_a.first["bindings"].as_h
      bindings["X"].to_s.should eq "bob"
    end

    it "returns structured error for malformed Prolog input" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      input = "parent(tom bob."
      result = tool.invoke({
        "solver" => JSON::Any.new("prolog"),
        "input"  => JSON::Any.new(input),
        "query"  => JSON::Any.new("parent(tom, X)."),
      })

      result["status"].as_s.should eq "success"
      result_hash = result["result"].as_h
      result_hash["status"].as_s.should eq "error"
    end

    it "includes unsatCore in unsat Z3 response" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      input = <<-SMT
        (declare-const x Int)
        (assert (! (> x 10) :named gt10))
        (assert (! (< x 5) :named lt5))
      SMT
      result = tool.invoke({
        "solver" => JSON::Any.new("z3"),
        "input"  => JSON::Any.new(input),
      })

      result["status"].as_s.should eq "success"
      result_hash = result["result"].as_h
      result_hash["status"].as_s.should eq "unsat"
      result_hash["unsat_core"].should_not be_nil
      core = result_hash["unsat_core"].as_a
      core.size.should be > 0
    end

    it "requires query parameter for prolog solver" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      input = "parent(tom, bob)."
      result = tool.invoke({
        "solver" => JSON::Any.new("prolog"),
        "input"  => JSON::Any.new(input),
      })

      result["status"].as_s.should eq "error"
      result["error"].to_s.should match(/query/i)
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

    it "runs multiple prolog queries against the same program" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      input = "edge(a, b). edge(b, c). edge(c, d)."
      queries = JSON.parse(%(["edge(a, X).", "edge(b, X).", "edge(c, X)."]))
      result = tool.invoke({
        "solver"  => JSON::Any.new("prolog"),
        "input"   => JSON::Any.new(input),
        "queries" => queries,
      })

      result["status"].as_s.should eq "success"
      results = result["result"].as_a
      results.size.should eq(3)
      results[0]["status"].as_s.should eq("success")
      results[0]["answers"].as_a.first["bindings"].as_h["X"].as_s.should eq("b")
      results[1]["answers"].as_a.first["bindings"].as_h["X"].as_s.should eq("c")
      results[2]["answers"].as_a.first["bindings"].as_h["X"].as_s.should eq("d")
    end

    it "rejects prolog queries arrays containing non-strings" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      result = tool.invoke({
        "solver"  => JSON::Any.new("prolog"),
        "input"   => JSON::Any.new("edge(a, b)."),
        "queries" => JSON.parse(%(["edge(a, X).", 1])),
      })

      result["status"].as_s.should eq "error"
      result["error"].as_s.should contain("queries array must contain only strings")
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
