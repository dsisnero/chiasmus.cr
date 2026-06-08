require "../../spec_helper"

private macro as_verify(result)
  result.as(Chiasmus::MCPServer::Types::VerifyResponse)
end

private macro as_error(result)
  result.as(Chiasmus::MCPServer::Types::ErrorResponse)
end

private def solver_result(result)
  as_verify(result).result || raise "Expected result"
end

describe Chiasmus::MCPServer::Tools::VerifyTool do
  describe "#invoke" do
    it "requires solver and input parameters" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new

      result = tool.invoke({"input" => JSON::Any.new("test")})
      result.status.should eq("error")
      as_error(result).error.should_not be_empty

      result = tool.invoke({"solver" => JSON::Any.new("z3")})
      result.status.should eq("error")
      as_error(result).error.should_not be_empty
    end

    it "handles unknown solver" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      result = tool.invoke({
        "solver" => JSON::Any.new("unknown"),
        "input"  => JSON::Any.new("test"),
      })

      result.status.should eq("error")
      as_error(result).error.should contain("Unknown solver")
    end

    it "returns actual result for z3 solver" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      input = "(declare-const x Int) (assert (> x 3))"
      result = tool.invoke({
        "solver" => JSON::Any.new("z3"),
        "input"  => JSON::Any.new(input),
      })

      result.status.should eq("success")
      sr = solver_result(result)
      sr.status.should eq("sat")
      model = sr.model || raise "Expected model"
      model.has_key?("x").should be_true
    end

    it "verifies unsatisfiable Z3 input" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      input = "(declare-const x Int) (assert (> x 10)) (assert (< x 5))"
      result = tool.invoke({
        "solver" => JSON::Any.new("z3"),
        "input"  => JSON::Any.new(input),
      })

      result.status.should eq("success")
      solver_result(result).status.should eq("unsat")
    end

    it "returns structured error for malformed Z3 input" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      input = %{(declare-const x Int) (assert (> x "bad"))}
      result = tool.invoke({
        "solver" => JSON::Any.new("z3"),
        "input"  => JSON::Any.new(input),
      })

      result.status.should eq("success")
      sr = solver_result(result)
      sr.status.should eq("error")
      err = sr.error || raise "Expected error"
      err.should_not be_empty
    end

    it "returns actual result for prolog solver" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      input = "parent(tom, bob). parent(bob, ann)."
      result = tool.invoke({
        "solver" => JSON::Any.new("prolog"),
        "input"  => JSON::Any.new(input),
        "query"  => JSON::Any.new("parent(tom, X)."),
      })

      result.status.should eq("success")
      sr = solver_result(result)
      sr.status.should eq("success")
      answers = sr.answers || raise "Expected answers"
      answers.size.should be >= 1
      answers.first.bindings["X"].should eq("bob")
    end

    it "returns structured error for malformed Prolog input" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      input = "parent(tom bob."
      result = tool.invoke({
        "solver" => JSON::Any.new("prolog"),
        "input"  => JSON::Any.new(input),
        "query"  => JSON::Any.new("parent(tom, X)."),
      })

      result.status.should eq("success")
      solver_result(result).status.should eq("error")
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

      result.status.should eq("success")
      sr = solver_result(result)
      sr.status.should eq("unsat")
      core = sr.unsat_core || raise "Expected unsat_core"
      core.size.should be > 0
    end

    it "requires query parameter for prolog solver" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      input = "parent(tom, bob)."
      result = tool.invoke({
        "solver" => JSON::Any.new("prolog"),
        "input"  => JSON::Any.new(input),
      })

      result.status.should eq("error")
      as_error(result).error.should match(/query/i)
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

      result.status.should eq("success")
      solver_result(result).status.should eq("success")
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

      result.status.should eq("success")
      verify = as_verify(result)
      batch = verify.results || raise "Expected results"
      batch.size.should eq(3)
      batch[0].status.should eq("success")
      a0 = batch[0].answers || raise "Expected answers[0]"
      a0.first.bindings["X"].should eq("b")
      a1 = batch[1].answers || raise "Expected answers[1]"
      a1.first.bindings["X"].should eq("c")
      a2 = batch[2].answers || raise "Expected answers[2]"
      a2.first.bindings["X"].should eq("d")
    end

    it "rejects prolog queries arrays containing non-strings" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      result = tool.invoke({
        "solver"  => JSON::Any.new("prolog"),
        "input"   => JSON::Any.new("edge(a, b)."),
        "queries" => JSON.parse(%(["edge(a, X).", 1])),
      })

      result.status.should eq("error")
      as_error(result).error.should contain("queries array must contain only strings")
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

      result.status.should eq("success")
      sr = solver_result(result)
      sr.status.should eq("success")
      trace = sr.trace || raise "Expected trace"
      trace.size.should be > 0
    end

    it "stops batch on first error" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      input = "edge(a, b). edge(b, c)."
      queries = JSON.parse(%[["edge(a, X).", "invalid(((", "edge(b, X)."]])
      result = tool.invoke({
        "solver"  => JSON::Any.new("prolog"),
        "input"   => JSON::Any.new(input),
        "queries" => queries,
      })

      result.status.should eq("success")
      verify = as_verify(result)
      batch = verify.results || raise "Expected results"
      batch.size.should eq(2)
      batch[0].status.should eq("success")
      batch[1].status.should eq("error")
    end
  end
end
