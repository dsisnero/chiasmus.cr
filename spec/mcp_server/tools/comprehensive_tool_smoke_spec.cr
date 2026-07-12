require "../../spec_helper"

# Comprehensive verification that all 12 chiasmus tools work
# through the invoke → typed output pipeline after dead code removal.

describe "All 12 chiasmus tools - post-refactor smoke test" do
  describe "chiasmus_verify" do
    it "Z3: returns SAT with model" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      r = tool.invoke({"solver" => JSON::Any.new("z3"), "input" => JSON::Any.new("(declare-const x Int) (assert (> x 0))")})
      r.status.should eq("success")
      v = r.as(Chiasmus::MCPServer::Types::VerifyResponse)
      v.result.try(&.status).should(eq("sat"))
      v.result.try(&.model).try(&.has_key?("x")).should(be_true)
    end

    it "Z3: returns UNSAT for contradiction" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      r = tool.invoke({"solver" => JSON::Any.new("z3"), "input" => JSON::Any.new("(declare-const x Int) (assert (> x 10)) (assert (< x 5))")})
      r.status.should eq("success")
      r.as(Chiasmus::MCPServer::Types::VerifyResponse).result.try(&.status).should(eq("unsat"))
    end

    it "Prolog: returns answers" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      r = tool.invoke({"solver" => JSON::Any.new("prolog"), "input" => JSON::Any.new("parent(tom, bob)."), "query" => JSON::Any.new("parent(tom, X).")})
      r.status.should eq("success")
      if answers = r.as(Chiasmus::MCPServer::Types::VerifyResponse).result.try(&.answers)
        answers.first.bindings["X"].should eq("bob")
      end
    end

    it "Prolog batch: returns individual results" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      input = "edge(a, b). edge(b, c)."
      queries = JSON.parse(%(["edge(a, X).", "edge(b, X)."]))
      r = tool.invoke({"solver" => JSON::Any.new("prolog"), "input" => JSON::Any.new(input), "queries" => queries})
      r.status.should eq("success")
      if batch = r.as(Chiasmus::MCPServer::Types::VerifyResponse).results
        batch.size.should eq(2)
        batch[0].status.should eq("success")
      end
    end

    it "rejects missing params with error" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      r = tool.invoke({"solver" => JSON::Any.new("z3")})
      r.status.should eq("error")
      r.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("input/spec")
    end

    it "rejects unknown solver" do
      tool = Chiasmus::MCPServer::Tools::VerifyTool.new
      r = tool.invoke({"solver" => JSON::Any.new("bad"), "input" => JSON::Any.new("x")})
      r.status.should eq("error")
      r.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("Unknown solver")
    end
  end

  describe "chiasmus_lint" do
    it "Z3: strips check-sat and returns cleaned spec" do
      tool = Chiasmus::MCPServer::Tools::LintTool.new
      r = tool.invoke({"solver" => JSON::Any.new("z3"), "input" => JSON::Any.new("(assert true)\n(check-sat)")})
      r.status.should eq("success")
      lint = r.as(Chiasmus::MCPServer::Types::LintResponse)
      lint.spec.should eq("(assert true)")
      lint.fixes.should_not be_empty
    end

    it "Prolog: catches missing periods" do
      tool = Chiasmus::MCPServer::Tools::LintTool.new
      r = tool.invoke({"solver" => JSON::Any.new("prolog"), "input" => JSON::Any.new("parent(tom, bob)\nparent(bob, ann)")})
      r.status.should eq("success")
      r.as(Chiasmus::MCPServer::Types::LintResponse).errors.should_not be_empty
    end

    it "rejects unknown solver" do
      tool = Chiasmus::MCPServer::Tools::LintTool.new
      r = tool.invoke({"solver" => JSON::Any.new("bad"), "input" => JSON::Any.new("x")})
      r.status.should eq("error")
    end
  end

  describe "chiasmus_skills" do
    it "lists starter templates" do
      server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
      begin
        Chiasmus::MCPServer.current_server = server
        tool = Chiasmus::MCPServer::Tools::SkillsTool.new
        r = tool.invoke({} of String => JSON::Any)
        r.status.should eq("success")
        r.as(Chiasmus::MCPServer::Types::SkillsResponse).templates.size.should be >= 8
      ensure
        server.skill_library.close rescue nil
        Chiasmus::MCPServer.current_server = nil
      end
    end

    it "searches by query" do
      server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
      begin
        Chiasmus::MCPServer.current_server = server
        tool = Chiasmus::MCPServer::Tools::SkillsTool.new
        r = tool.invoke({"query" => JSON::Any.new("access control")})
        r.status.should eq("success")
        r.as(Chiasmus::MCPServer::Types::SkillsResponse).templates.should_not be_empty
      ensure
        server.skill_library.close rescue nil
        Chiasmus::MCPServer.current_server = nil
      end
    end

    it "filters by solver type" do
      server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
      begin
        Chiasmus::MCPServer.current_server = server
        tool = Chiasmus::MCPServer::Tools::SkillsTool.new
        r = tool.invoke({"solver" => JSON::Any.new("prolog")})
        r.status.should eq("success")
        r.as(Chiasmus::MCPServer::Types::SkillsResponse).templates.each do |template|
          template.solver.should eq("prolog")
        end
      ensure
        server.skill_library.close rescue nil
        Chiasmus::MCPServer.current_server = nil
      end
    end

    it "returns error for nonexistent template" do
      server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
      begin
        Chiasmus::MCPServer.current_server = server
        tool = Chiasmus::MCPServer::Tools::SkillsTool.new
        r = tool.invoke({"name" => JSON::Any.new("nonexistent-template")})
        r.status.should eq("error")
        r.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("not found")
      ensure
        server.skill_library.close rescue nil
        Chiasmus::MCPServer.current_server = nil
      end
    end
  end

  describe "chiasmus_formalize" do
    it "returns error when server not available" do
      Chiasmus::MCPServer.current_server = nil
      tool = Chiasmus::MCPServer::Tools::FormalizeTool.new
      r = tool.invoke({"problem" => JSON::Any.new("test")})
      r.status.should eq("error")
      r.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("Server")
    ensure
      Chiasmus::MCPServer.current_server = nil
    end

    it "returns template instructions with mock server" do
      server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).with_agent_builder(
        Chiasmus::LLM::MockClient.new.agent("mock")
      )
      Chiasmus::MCPServer.current_server = server
      tool = Chiasmus::MCPServer::Tools::FormalizeTool.new
      r = tool.invoke({"problem" => JSON::Any.new("Check if access control rules can conflict")})
      r.status.should eq("success")
      f = r.as(Chiasmus::MCPServer::Types::FormalizeResponse)
      f.template.should_not be_empty
      f.solver.should_not be_empty
      f.instructions.should contain("SLOT")
    ensure
      Chiasmus::MCPServer.current_server = nil
    end

    it "returns error for empty problem" do
      tool = Chiasmus::MCPServer::Tools::FormalizeTool.new
      r = tool.invoke({"problem" => JSON::Any.new("")})
      r.status.should eq("error")
    end
  end

  describe "chiasmus_solve" do
    it "falls back to template when no LLM configured" do
      server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
      Chiasmus::MCPServer.current_server = server
      tool = Chiasmus::MCPServer::Tools::SolveTool.new
      r = tool.invoke({"problem" => JSON::Any.new("Check if access control rules conflict")})
      r.status.should eq("success")
      s = r.as(Chiasmus::MCPServer::Types::SolveResponse)
      s.fallback.should be_true
      s.template_used.try(&.should(eq("policy-contradiction")))
      s.message.try(&.should(contain("verify")))
    ensure
      Chiasmus::MCPServer.current_server = nil
    end

    it "returns error for missing problem" do
      tool = Chiasmus::MCPServer::Tools::SolveTool.new
      r = tool.invoke({} of String => JSON::Any)
      r.status.should eq("error")
      r.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("problem")
    end
  end

  describe "chiasmus_learn" do
    it "returns error when no learner is available" do
      server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
      Chiasmus::MCPServer.current_server = server
      tool = Chiasmus::MCPServer::Tools::LearnTool.new
      r = tool.invoke({"solver" => JSON::Any.new("z3"), "spec" => JSON::Any.new("(assert true)"), "problem" => JSON::Any.new("test")})
      r.status.should eq("error")
      r.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("LLM")
    ensure
      Chiasmus::MCPServer.current_server = nil
    end

    it "rejects missing parameters" do
      tool = Chiasmus::MCPServer::Tools::LearnTool.new
      r = tool.invoke({"solver" => JSON::Any.new("z3")})
      r.status.should eq("error")
    end
  end

  describe "chiasmus_graph" do
    it "returns error for missing files" do
      tool = Chiasmus::MCPServer::Tools::GraphTool.new
      r = tool.invoke({"analysis" => JSON::Any.new("summary")})
      r.status.should eq("error")
      r.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("files")
    end

    it "rejects unknown analysis type" do
      tool = Chiasmus::MCPServer::Tools::GraphTool.new
      r = tool.invoke({"files" => JSON.parse(%(["/nonexistent"])), "analysis" => JSON::Any.new("bad")})
      r.status.should eq("error")
      r.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("Unknown analysis")
    end

    it "returns summary for real source file" do
      tmpdir = Dir.tempdir
      path = File.join(tmpdir, "smoke.go")
      begin
        File.write(path, "package main\nfunc main() { helper() }\nfunc helper() {}")
        tool = Chiasmus::MCPServer::Tools::GraphTool.new
        r = tool.invoke({"files" => JSON.parse([path].to_json), "analysis" => JSON::Any.new("summary")})
        r.status.should eq("success")
        g = r.as(Chiasmus::MCPServer::Types::GraphResponse)
        g.analysis.should eq("summary")
      ensure
        File.delete(path) if File.exists?(path)
      end
    end
  end

  describe "chiasmus_map" do
    it "returns overview for source file" do
      tmpdir = Dir.tempdir
      path = File.join(tmpdir, "map_smoke.go")
      begin
        File.write(path, "package main\nfunc main() { helper() }\nfunc helper() {}")
        tool = Chiasmus::MCPServer::Tools::MapTool.new
        r = tool.invoke({"files" => JSON.parse([path].to_json), "mode" => JSON::Any.new("overview")})
        r.status.should eq("success")
        r.as(Chiasmus::MCPServer::Types::MapResponse).content.should_not be_empty
      ensure
        File.delete(path) if File.exists?(path)
      end
    end

    it "returns error for empty files" do
      tool = Chiasmus::MCPServer::Tools::MapTool.new
      r = tool.invoke({"files" => JSON.parse(%([]))})
      r.status.should eq("error")
    end
  end

  describe "chiasmus_review" do
    it "returns review plan for source file" do
      tmpdir = Dir.tempdir
      path = File.join(tmpdir, "review_smoke.go")
      begin
        File.write(path, "package main\nfunc main() { helper() }\nfunc helper() {}")
        tool = Chiasmus::MCPServer::Tools::ReviewTool.new
        r = tool.invoke({"files" => JSON.parse([path].to_json), "focus" => JSON::Any.new("quick")})
        r.status.should eq("success")
        rev = r.as(Chiasmus::MCPServer::Types::ReviewResponse)
        rev.focus.should eq("quick")
        rev.phases.should_not be_empty
      ensure
        File.delete(path) if File.exists?(path)
      end
    end

    it "returns error for empty files" do
      tool = Chiasmus::MCPServer::Tools::ReviewTool.new
      r = tool.invoke({"files" => JSON.parse(%([]))})
      r.status.should eq("error")
    end
  end

  describe "chiasmus_craft" do
    it "creates a template" do
      dir = File.join(Dir.tempdir, "chiasmus-smoke-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(dir)
      begin
        with_env({"CHIASMUS_HOME" => dir}) do
          server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
          Chiasmus::MCPServer.current_server = server
          tool = Chiasmus::MCPServer::Tools::CraftTool.new
          r = tool.invoke({
            "name"           => JSON::Any.new("smoke-template"),
            "domain"         => JSON::Any.new("validation"),
            "solver"         => JSON::Any.new("z3"),
            "signature"      => JSON::Any.new("smoke test"),
            "skeleton"       => JSON::Any.new("(assert {{SLOT:x}})"),
            "slots"          => JSON.parse(%([{"name":"x","description":"d","format":"f"}])),
            "normalizations" => JSON.parse(%([{"source":"s","transform":"t"}])),
          })
          r.status.should eq("success")
          r.as(Chiasmus::MCPServer::Types::CraftResponse).created.should be_true
        end
      ensure
        FileUtils.rm_rf(dir) if Dir.exists?(dir)
        Chiasmus::MCPServer.current_server = nil
      end
    end

    it "rejects duplicate template name" do
      dir = File.join(Dir.tempdir, "chiasmus-smoke-#{Random::Secure.hex(8)}")
      Dir.mkdir_p(dir)
      begin
        with_env({"CHIASMUS_HOME" => dir}) do
          server = Chiasmus::MCPServer::Server(Chiasmus::LLM::MockCompletionModel).new
          Chiasmus::MCPServer.current_server = server
          tool = Chiasmus::MCPServer::Tools::CraftTool.new
          args = {
            "name"           => JSON::Any.new("dup-template"),
            "domain"         => JSON::Any.new("validation"),
            "solver"         => JSON::Any.new("z3"),
            "signature"      => JSON::Any.new("first"),
            "skeleton"       => JSON::Any.new("(assert {{SLOT:x}})"),
            "slots"          => JSON.parse(%([{"name":"x","description":"d","format":"f"}])),
            "normalizations" => JSON.parse(%([{"source":"s","transform":"t"}])),
          }
          tool.invoke(args)
          r = tool.invoke(args)
          r.status.should eq("success")
          r.as(Chiasmus::MCPServer::Types::CraftResponse).created.should be_false
        end
      ensure
        FileUtils.rm_rf(dir) if Dir.exists?(dir)
        Chiasmus::MCPServer.current_server = nil
      end
    end
  end

  describe "chiasmus_crig" do
    it "returns error for missing prompt" do
      tool = Chiasmus::MCPServer::Tools::CrigTool.new
      r = tool.invoke({} of String => JSON::Any)
      r.status.should eq("error")
      r.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("prompt")
    end

    it "returns error when no API key configured" do
      with_env({
        "OPENAI_API_KEY"   => nil,
        "DEEPSEEK_API_KEY" => nil,
      }) do
        tool = Chiasmus::MCPServer::Tools::CrigTool.new
        r = tool.invoke({"prompt" => JSON::Any.new("hello")})
        r.status.should eq("error")
        r.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("API key")
      end
    end
  end

  describe "chiasmus_search" do
    it "returns error for missing query" do
      tool = Chiasmus::MCPServer::Tools::SearchTool.new
      r = tool.invoke({"files" => JSON.parse(%([]))})
      r.status.should eq("error")
      r.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("query")
    end

    it "returns error for missing files" do
      tool = Chiasmus::MCPServer::Tools::SearchTool.new
      r = tool.invoke({"query" => JSON::Any.new("test")})
      r.status.should eq("error")
      r.as(Chiasmus::MCPServer::Types::ErrorResponse).error.should contain("files")
    end

    it "has correct input schema" do
      schema = Chiasmus::MCPServer::Tools::SearchTool.input_schema
      schema.properties.has_key?("query").should be_true
      schema.properties.has_key?("files").should be_true
      schema.properties.has_key?("languages").should be_true
      schema.properties.has_key?("kinds").should be_true
    end
  end

  describe "tool metadata completeness" do
    it "all 12 tools have non-empty name and description" do
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
        Chiasmus::MCPServer::Tools::CraftTool,
        Chiasmus::MCPServer::Tools::ReviewTool,
        Chiasmus::MCPServer::Tools::CrigTool,
      ]
      tools.each do |klass|
        klass.tool_name.should_not be_empty
        klass.tool_name.should start_with("chiasmus_")
        klass.tool_description.should_not be_empty
        klass.input_schema.should_not be_nil
      end
    end
  end

  describe "typed input struct roundtrip" do
    it "VerifyInput round-trips through JSON" do
      original = Chiasmus::MCPServer::Types::VerifyInput.from_json({
        "solver"  => "prolog",
        "input"   => "edge(a,b).",
        "queries" => ["edge(a,X)."],
        "explain" => true,
        "format"  => "mermaid",
      }.to_json)
      original.solver.should eq("prolog")
      original.input.should eq("edge(a,b).")
      original.queries.try(&.should(eq(["edge(a,X)."])))
      original.explain.should be_true
      original.format.should eq("mermaid")
    end

    it "CraftInput round-trips with slots and normalizations" do
      original = Chiasmus::MCPServer::Types::CraftInput.from_json({
        "name"           => "test",
        "domain"         => "validation",
        "solver"         => "z3",
        "signature"      => "test sig",
        "skeleton"       => "(assert {{SLOT:x}})",
        "slots"          => [{"name" => "x", "description" => "desc", "format" => "fmt"}],
        "normalizations" => [{"source" => "src", "transform" => "tr"}],
      }.to_json)
      original.slots[0].name.should eq("x")
      original.normalizations[0].source.should eq("src")
    end
  end
end
